provider "aws" {
  region = "us-east-1"
}

# --- 1. USER CONFIGURATION (EDIT THIS) ---
variable "lastname" {
  default = "kaif" # REPLACE with your last name (lowercase)
}
variable "github_repo" {
  default = "kaif9711/assignment2-aws" # REPLACE with your GitHub user/repo
}
variable "codestar_arn" {
  default = "arn:aws:codeconnections:us-east-1:519139471137:connection/99efed42-bddd-4f75-8dba-930edd48b3aa" # REPLACE with your Connection ARN
}

# --- 2. VPC & NETWORK ---
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  tags                 = { Name = "${var.lastname}-vpc" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
}

# 2 Public Subnets (For Load Balancer)
resource "aws_subnet" "public" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index)
  availability_zone = element(["us-east-1a", "us-east-1b"], count.index)
  map_public_ip_on_launch = true
}

# 2 Private Subnets (For Application)
resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index + 10)
  availability_zone = element(["us-east-1a", "us-east-1b"], count.index)
}

# NAT Gateway (Required for Private Subnets to pull Docker images)
resource "aws_eip" "nat" { domain = "vpc" }
resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
}

# Routing
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}
resource "aws_route_table_association" "pub_assoc" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
}
resource "aws_route_table_association" "priv_assoc" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# --- 3. SECURITY ---
resource "aws_security_group" "alb_sg" {
  name   = "${var.lastname}-alb-sg"
  vpc_id = aws_vpc.main.id
  ingress {
    from_port = 80
    to_port   = 80
    protocol  = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "ecs_sg" {
  name   = "${var.lastname}-ecs-sg"
  vpc_id = aws_vpc.main.id
  ingress {
    from_port       = 5000
    to_port         = 5000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }
  egress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- 4. ECR REPOSITORY ---
resource "aws_ecr_repository" "repo" {
  name         = "${var.lastname}-repo"
  force_delete = true
  image_scanning_configuration {
    scan_on_push = true
  }
}

# --- 5. LOAD BALANCER ---
resource "aws_lb" "alb" {
  name               = "${var.lastname}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = aws_subnet.public[*].id
}

resource "aws_lb_target_group" "tg" {
  name        = "${var.lastname}-tg"
  port        = 5000
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.main.id
  health_check { path = "/" }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.alb.arn
  port              = "80"
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg.arn
  }
}

# --- 6. ECS CLUSTER & SERVICE ---
resource "aws_ecs_cluster" "cluster" {
  name = "${var.lastname}-cluster"
}

resource "aws_iam_role" "exec_role" {
  name = "${var.lastname}-exec-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "ecs-tasks.amazonaws.com" } }]
  })
}
resource "aws_iam_role_policy_attachment" "exec_att" {
  role       = aws_iam_role.exec_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_ecs_task_definition" "task" {
  family                   = "${var.lastname}-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.exec_role.arn
  container_definitions = jsonencode([
    {
      name      = "app"
      image     = "${aws_ecr_repository.repo.repository_url}:latest"
      essential = true
      portMappings = [{ containerPort = 5000 }]
    }
  ])
}

resource "aws_ecs_service" "service" {
  name            = "${var.lastname}-service"
  cluster         = aws_ecs_cluster.cluster.id
  task_definition = aws_ecs_task_definition.task.arn
  desired_count   = 2
  launch_type     = "FARGATE"
  network_configuration {
    subnets         = aws_subnet.private[*].id
    security_groups = [aws_security_group.ecs_sg.id]
    assign_public_ip = false
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.tg.arn
    container_name   = "app"
    container_port   = 5000
  }
  depends_on = [aws_lb_listener.http]
}

# --- 7. CODEPIPELINE ---
resource "aws_s3_bucket" "artifacts" {
  bucket        = "${var.lastname}-pipeline-artifacts-12345" # ADD RANDOM NUMBERS to be unique
  force_destroy = true
}

resource "aws_iam_role" "codepipeline_role" {
  name = "${var.lastname}-pipeline-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17", Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "codepipeline.amazonaws.com" } }]
  })
}
resource "aws_iam_role_policy_attachment" "cp_admin" {
  role       = aws_iam_role.codepipeline_role.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_role" "codebuild_role" {
  name = "${var.lastname}-codebuild-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17", Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "codebuild.amazonaws.com" } }]
  })
}
resource "aws_iam_role_policy_attachment" "cb_admin" {
  role       = aws_iam_role.codebuild_role.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_codebuild_project" "build" {
  name         = "${var.lastname}-build"
  service_role = aws_iam_role.codebuild_role.arn
  artifacts { type = "CODEPIPELINE" }
  environment {
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = "aws/codebuild/amazonlinux2-x86_64-standard:5.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = true
  }
  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec.yml"
  }
}

resource "aws_codepipeline" "pipeline" {
  name     = "${var.lastname}-pipeline"
  role_arn = aws_iam_role.codepipeline_role.arn
  artifact_store {
    location = aws_s3_bucket.artifacts.bucket
    type     = "S3"
  }
  stage {
    name = "Source"
    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["source_output"]
      configuration = {
        ConnectionArn    = var.codestar_arn
        FullRepositoryId = var.github_repo
        BranchName       = "main"
      }
    }
  }
  stage {
    name = "Build"
    action {
      name             = "Build"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      input_artifacts  = ["source_output"]
      output_artifacts = ["build_output"]
      version          = "1"
      configuration = { ProjectName = aws_codebuild_project.build.name }
    }
  }
  stage {
    name = "Approval"
    action {
      name     = "Approval"
      category = "Approval"
      owner    = "AWS"
      provider = "Manual"
      version  = "1"
    }
  }
  stage {
    name = "Deploy"
    action {
      name            = "Deploy"
      category        = "Deploy"
      owner           = "AWS"
      provider        = "ECS"
      input_artifacts = ["build_output"]
      version         = "1"
      configuration = {
        ClusterName = aws_ecs_cluster.cluster.name
        ServiceName = aws_ecs_service.service.name
      }
    }
  }
}