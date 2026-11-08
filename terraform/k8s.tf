resource "aws_security_group" "k8s" {
  count = var.enable_k8s ? 1 : 0

  name        = "${var.project}-k8s"
  description = "k3s node: public HTTP via Traefik, admin access restricted"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "HTTP (Traefik ingress)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS (Traefik ingress)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  dynamic "ingress" {
    for_each = {
      22                     = "SSH"
      6443                   = "Kubernetes API (kubectl)"
      (var.argocd_nodeport)  = "Argo CD UI"
      (var.grafana_nodeport) = "Grafana"
    }
    content {
      description = ingress.value
      from_port   = ingress.key
      to_port     = ingress.key
      protocol    = "tcp"
      cidr_blocks = var.admin_cidrs
    }
  }

  #trivy:ignore:AWS-0104
  egress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  #trivy:ignore:AWS-0104
  egress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_eip" "k8s" {
  count  = var.enable_k8s ? 1 : 0
  domain = "vpc"

  tags = {
    Name = "${var.project}-k8s"
  }
}

resource "aws_instance" "k8s" {
  count = var.enable_k8s ? 1 : 0

  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.k8s_instance_type
  key_name               = aws_key_pair.deploy.key_name
  vpc_security_group_ids = [aws_security_group.k8s[0].id]

  user_data = templatefile("${path.module}/templates/bootstrap-k3s.sh.tftpl", {
    public_ip          = aws_eip.k8s[0].public_ip
    k3s_version        = var.k3s_version
    argocd_version     = var.argocd_version
    argocd_nodeport    = var.argocd_nodeport
    admin_password     = var.admin_password
    root_app_manifest  = file("${path.module}/../argocd/root.yaml")
  })
  user_data_replace_on_change = true

  root_block_device {
    volume_type = "gp3"
    volume_size = 20
    encrypted   = true
  }

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  tags = {
    Name = "${var.project}-k8s"
  }

  lifecycle {
    ignore_changes = [ami]
  }
}

resource "aws_eip_association" "k8s" {
  count         = var.enable_k8s ? 1 : 0
  instance_id   = aws_instance.k8s[0].id
  allocation_id = aws_eip.k8s[0].id
}
