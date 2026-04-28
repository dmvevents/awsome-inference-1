# CodeBuild setup — dynamo-inference

After the option-A change (no default on `ARG NETWORKING_BASE`) the AWS
CodeBuild pipeline needs to be wired deliberately. This doc is the runbook
for one-time infrastructure bring-up plus the model CodePipeline.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│ CodePipeline: dynamo-inference                                  │
│                                                                 │
│  Source (GitHub) ─►  BUILD_BASE ────────►  BUILD_APP            │
│                      buildspec-base.yml    buildspec-app.yml    │
│                      (25 min cold,         (10 min, 35 min      │
│                       5 min warm)           combined cold)      │
└──────────┬────────────────────┬──────────────────┬──────────────┘
           ▼                    ▼                  ▲
    GitHub webhook     Private ECR                 │
                       networking-base:v5  ◄───────┘
                       efa-rdma-base:v1
                       awsi-efa-base:<sha>
                       awsi-dynamo-combined-efa:<sha>

                       S3 bucket (optional)
                       s3://dist-sboms/<sha>/sbom/
                       s3://dist-sboms/<sha>/cve/
```

Two CodeBuild projects on purpose:

1. **BUILD_BASE** — produces `efa-rdma-base:v1` + `networking-base:v5`, only
    triggered when base Dockerfiles change (25 min cold). Pulls source from
    the `awesome-inferencing` monorepo because the base Dockerfiles live
    there, not in this repo.
2. **BUILD_APP** — consumes `networking-base:v5` from ECR + this repo's
    source. Runs on every push (5-10 min).

Separating them keeps app builds fast and gives base rebuilds a clean
audit trail.

---

## Prerequisites

- AWS account with a CodeBuild-capable region (recommended: `us-east-2`)
- GitHub connection to this repo authorized in CodeStar Connections
- IAM user/role to create CloudFormation stacks

---

## One-time bootstrap

### 1. Create the private ECR repos

```bash
REGION=us-east-2
for repo in \
    efa-rdma-base \
    networking-base \
    awsi-efa-base \
    awsi-dynamo-combined-efa; do
  aws ecr create-repository --repository-name "$repo" \
    --region "$REGION" \
    --image-scanning-configuration scanOnPush=true \
    --encryption-configuration encryptionType=AES256 \
    || echo "  $repo already exists"
done
```

Apply a lifecycle policy that keeps the last 10 SHA-tagged images + the
`latest` / `v5` / `v1` rolling tags, and expires untagged after 1 day:

```bash
cat > /tmp/ecr-lifecycle.json <<'EOF'
{
  "rules": [
    { "rulePriority": 1, "description": "keep mutable tags",
      "selection": { "tagStatus": "tagged", "tagPatternList": ["latest","v*"], "countType": "imageCountMoreThan", "countNumber": 10 },
      "action": { "type": "expire" } },
    { "rulePriority": 2, "description": "keep last 10 SHA-tagged",
      "selection": { "tagStatus": "tagged", "tagPatternList": ["*"], "countType": "imageCountMoreThan", "countNumber": 10 },
      "action": { "type": "expire" } },
    { "rulePriority": 3, "description": "expire untagged",
      "selection": { "tagStatus": "untagged", "countType": "sinceImagePushed", "countUnit": "days", "countNumber": 1 },
      "action": { "type": "expire" } }
  ]
}
EOF

for repo in efa-rdma-base networking-base awsi-efa-base awsi-dynamo-combined-efa; do
  aws ecr put-lifecycle-policy --repository-name "$repo" \
    --region "$REGION" --lifecycle-policy-text file:///tmp/ecr-lifecycle.json
done
```

### 2. Create the CodeBuild service role

Trust policy — CodeBuild only:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "codebuild.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
```

Inline policy (minimum required — tighten Resource scoping in prod):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "arn:aws:logs:*:*:log-group:/aws/codebuild/*"
    },
    {
      "Effect": "Allow",
      "Action": ["ecr:GetAuthorizationToken"],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:DescribeRepositories",
        "ecr:CreateRepository",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload",
        "ecr:PutImage"
      ],
      "Resource": [
        "arn:aws:ecr:us-east-2:058264135704:repository/efa-rdma-base",
        "arn:aws:ecr:us-east-2:058264135704:repository/networking-base",
        "arn:aws:ecr:us-east-2:058264135704:repository/awsi-efa-base",
        "arn:aws:ecr:us-east-2:058264135704:repository/awsi-dynamo-combined-efa"
      ]
    },
    {
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject"],
      "Resource": "arn:aws:s3:::<your-sbom-bucket>/*"
    }
  ]
}
```

Substitute `058264135704` + `us-east-2` + `<your-sbom-bucket>` for your
account / region / bucket.

### 3. Create the two CodeBuild projects

#### BUILD_BASE

```bash
aws codebuild create-project \
  --name dynamo-inference-base \
  --region us-east-2 \
  --source type=GITHUB,location=https://github.com/dmvevents/awsome-inference-1.git,buildspec=2.projects/dynamo-inference/buildspec-base.yml \
  --artifacts type=NO_ARTIFACTS \
  --environment "type=LINUX_CONTAINER,computeType=BUILD_GENERAL1_LARGE,image=aws/codebuild/amazonlinux2-x86_64-standard:5.0,privilegedMode=true,environmentVariables=[
    {name=AWS_ACCOUNT_ID,value=058264135704},
    {name=AWS_DEFAULT_REGION,value=us-east-2},
    {name=ECR_REPO_PREFIX,value=},
    {name=BASE_SOURCE_REPO,value=https://github.com/aws-samples/awesome-inferencing.git},
    {name=BASE_SOURCE_BRANCH,value=main}
  ]" \
  --service-role arn:aws:iam::058264135704:role/CodeBuildDynamoInferenceRole \
  --timeout-in-minutes 60
```

#### BUILD_APP

```bash
aws codebuild create-project \
  --name dynamo-inference-app \
  --region us-east-2 \
  --source type=GITHUB,location=https://github.com/dmvevents/awsome-inference-1.git,buildspec=2.projects/dynamo-inference/buildspec-app.yml \
  --artifacts type=NO_ARTIFACTS \
  --environment "type=LINUX_CONTAINER,computeType=BUILD_GENERAL1_2XLARGE,image=aws/codebuild/amazonlinux2-x86_64-standard:5.0,privilegedMode=true,environmentVariables=[
    {name=AWS_ACCOUNT_ID,value=058264135704},
    {name=AWS_DEFAULT_REGION,value=us-east-2},
    {name=ECR_REPO_PREFIX,value=},
    {name=NETWORKING_BASE_URI,value=058264135704.dkr.ecr.us-east-2.amazonaws.com/networking-base:v5},
    {name=CUDA_ARCH,value=90},
    {name=S3_SBOM_BUCKET,value=s3://your-sbom-bucket/dynamo-inference},
    {name=CVE_ALLOW_CRITICAL,value=0}
  ]" \
  --service-role arn:aws:iam::058264135704:role/CodeBuildDynamoInferenceRole \
  --timeout-in-minutes 90
```

Compute-type notes:
- `BUILD_GENERAL1_LARGE` (8 vCPU / 15 GB / 200 GB SSD) — enough for
  networking-base:v5. Build ~25 min cold.
- `BUILD_GENERAL1_2XLARGE` (72 vCPU / 145 GB / 824 GB SSD) — required for
  the combined image. The 48 GB image overflows LARGE's scratch during
  `exporting layers`.
- `privilegedMode: true` — required for Docker-in-Docker. Without this,
  `docker build` errors with `Cannot connect to the Docker daemon`.

### 4. One-off bootstrap push

CodeBuild pulls `networking-base:v5` before building. It doesn't exist in
ECR the first time around. Fix: either

**(a)** push it once from a workstation that already built it:

```bash
docker build -t networking-base:v5 base/networking-base/          # in awesome-inferencing
docker tag networking-base:v5 058264135704.dkr.ecr.us-east-2.amazonaws.com/networking-base:v5
aws ecr get-login-password --region us-east-2 | docker login --username AWS \
    --password-stdin 058264135704.dkr.ecr.us-east-2.amazonaws.com
docker push 058264135704.dkr.ecr.us-east-2.amazonaws.com/networking-base:v5
```

**(b)** trigger `dynamo-inference-base` manually in the console. Its
`pre_build.docker pull` step handles missing images gracefully (`|| echo`)
and BuildKit's `--cache-from` skips cache when the reference isn't there.

Going forward, the base project's CodeStar trigger only fires when files
under `base/**` in the `awesome-inferencing` monorepo change (set a
GitHub webhook file-path filter), so it usually sleeps.

---

## Wiring CodePipeline (optional)

If you want automated promotion (source → base → app → test), use this
minimal CloudFormation:

```yaml
Resources:
  Pipeline:
    Type: AWS::CodePipeline::Pipeline
    Properties:
      RoleArn: !GetAtt PipelineRole.Arn
      ArtifactStore:
        Type: S3
        Location: !Ref ArtifactBucket
      Stages:
        - Name: Source
          Actions:
            - Name: GitHubSource
              ActionTypeId:
                Category: Source
                Owner: AWS
                Provider: CodeStarSourceConnection
                Version: '1'
              Configuration:
                ConnectionArn: !Ref GitHubConnection
                FullRepositoryId: dmvevents/awsome-inference-1
                BranchName: feature/dynamo-combined-vllm-trtllm-efa
              OutputArtifacts:
                - Name: SourceOutput
        - Name: BuildBase
          Actions:
            - Name: BuildNetworkingBase
              ActionTypeId:
                Category: Build
                Owner: AWS
                Provider: CodeBuild
                Version: '1'
              Configuration:
                ProjectName: dynamo-inference-base
              InputArtifacts: [{ Name: SourceOutput }]
              OutputArtifacts: [{ Name: BaseOutput }]
        - Name: BuildApp
          Actions:
            - Name: BuildAppImages
              ActionTypeId:
                Category: Build
                Owner: AWS
                Provider: CodeBuild
                Version: '1'
              Configuration:
                ProjectName: dynamo-inference-app
                EnvironmentVariables: |
                  [
                    { "name": "NETWORKING_BASE_URI", "value": "#{BuildNetworkingBase.NETWORKING_BASE_URI}", "type": "PLAINTEXT" }
                  ]
              InputArtifacts: [{ Name: SourceOutput }]
              OutputArtifacts: [{ Name: AppOutput }]
```

The `#{...}` reference pulls the exported `NETWORKING_BASE_URI` from the
base build's output variables (exposed by `exported-variables:` in
`buildspec-base.yml`).

---

## Troubleshooting

### "ARG NETWORKING_BASE: required argument" during docker build

The Dockerfiles enforce option A — no default. Confirm:
`docker build ... --build-arg NETWORKING_BASE=<registry>/networking-base:v5 ...`
is actually being passed. `build.sh` does this automatically if you pass
`--networking-base` or set `NETWORKING_BASE` env.

### "Cannot connect to the Docker daemon"

Set `PrivilegedMode: true` on the CodeBuild project. CodeBuild doesn't
run a Docker daemon by default.

### "no space left on device" during combined export

You're on `BUILD_GENERAL1_LARGE`. Upgrade to `BUILD_GENERAL1_2XLARGE`.
The combined image is 48 GB; LARGE has a 200 GB scratch disk but the
Docker overlayfs write-amplification pushes it over when tagging both
SHA and `latest`.

### Base build hangs on "network: dial tcp: lookup nvcr.io: i/o timeout"

CodeBuild VPC config is missing a NAT gateway or VPC endpoint. Either
run the project in a public subnet (no VPC config) or add an S3 / ECR
VPC endpoint + NAT gateway to the CodeBuild VPC.

### CVE gate fails on a known false-positive

Set `CVE_ALLOW_CRITICAL=1` on the CodeBuild project as a temporary
override. For permanent suppression, add an `.trivyignore` file to the
repo root listing `CVE-XXXX-XXXX` one per line — trivy picks it up
automatically.

---

## Referenced files (paths relative to 2.projects/dynamo-inference/)

- `build.sh` — `--networking-base` flag added; required (no default).
- `buildspec-base.yml` — builds networking-base + efa-rdma-base.
- `buildspec-app.yml` — builds the app images, runs CVE gate, uploads SBOMs.
- `sbom/CVE-SUMMARY.md` — last known-good CVE ground truth for these images.
