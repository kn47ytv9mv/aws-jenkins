# Security Groups

resource "aws_security_group" "alb" {
  name   = "${var.name_prefix}-alb-sg"
  vpc_id = var.vpc_id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "jenkins" {
  name   = "${var.name_prefix}-jenkins-sg"
  vpc_id = var.vpc_id

  ingress {
    from_port       = var.port
    to_port         = var.port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

output "jenkins_sg_id" {
  value = aws_security_group.jenkins.id
}

# EFS

resource "aws_security_group" "efs" {
  name   = "${var.name_prefix}-efs-sg"
  vpc_id = var.vpc_id

  ingress {
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_security_group.jenkins.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_efs_file_system" "jenkins" {
  encrypted = true
}

resource "aws_efs_mount_target" "jenkins" {
  security_groups = [aws_security_group.efs.id]
  file_system_id  = aws_efs_file_system.jenkins.id
  subnet_id       = var.private_subnet_ids[count.index]

  count = length(var.private_subnet_ids)
}

resource "aws_efs_access_point" "jenkins" {
  file_system_id = aws_efs_file_system.jenkins.id

  posix_user {
    uid = 1000
    gid = 1000
  }

  root_directory {
    path = "/jenkins_home"

    creation_info {
      owner_uid   = 1000
      owner_gid   = 1000
      permissions = "0775"
    }
  }
}

# IAM

data "aws_iam_policy_document" "ecs_task_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "ecs_exec_managed" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "ecs_task_execution" {
  name               = "${var.name_prefix}-ecs-exec-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume.json
}

resource "aws_iam_role" "ecs_task" {
  name               = "${var.name_prefix}-ecs-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume.json
}

# ECS

resource "aws_cloudwatch_log_group" "jenkins" {
  name              = "/ecs/${var.name_prefix}/jenkins"
  retention_in_days = 14
}

resource "aws_ecs_cluster" "this" {
  name = "${var.name_prefix}-cluster"
}

resource "aws_ecs_task_definition" "jenkins" {
  family                   = "${var.name_prefix}-jenkins"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.cpu
  memory                   = var.memory

  execution_role_arn = aws_iam_role.ecs_task_execution.arn
  task_role_arn      = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([
    {
      name      = "jenkins"
      image     = var.image
      essential = true

      portMappings = [
        {
          containerPort = var.port
          hostPort      = var.port
          protocol      = "tcp"
        }
      ]

      environment = [
        { name = "JAVA_OPTS", value = "-Djenkins.install.runSetupWizard=false" }
      ]

      mountPoints = [
        {
          sourceVolume  = var.home
          containerPath = "/var/${var.home}"
          readOnly      = false
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.jenkins.name
          awslogs-region        = aws_cloudwatch_log_group.jenkins.region
          awslogs-stream-prefix = "ecs"
        }
      }
    }
  ])

  volume {
    name = var.home

    efs_volume_configuration {
      file_system_id     = aws_efs_file_system.jenkins.id
      transit_encryption = "ENABLED"

      authorization_config {
        access_point_id = aws_efs_access_point.jenkins.id
        iam             = "DISABLED"
      }
    }
  }
}

resource "aws_ecs_service" "jenkins" {
  name            = "${var.name_prefix}-jenkins-svc"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.jenkins.arn
  desired_count   = 2

  launch_type = "FARGATE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.jenkins.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.jenkins.arn
    container_name   = var.name
    container_port   = var.port
  }

  depends_on = [aws_efs_mount_target.jenkins, aws_lb_listener.http]
}

# ALB (HTTP only)

resource "aws_lb" "jenkins" {
  name               = "jenkins-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.public_subnet_ids
}

resource "aws_lb_target_group" "jenkins" {
  name        = substr("${var.name_prefix}-tg", 0, 32)
  port        = var.port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = "/login"
    protocol            = "HTTP"
    matcher             = var.alb_healthy_http_codes
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  stickiness {
    type            = "lb_cookie"
    enabled         = true
    cookie_duration = 86400
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.jenkins.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.jenkins.arn
  }
}

