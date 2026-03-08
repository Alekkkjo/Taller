# =============================================================================
# Semana 8 – Taller: Infraestructura bajo código en AWS con Terraform
# Autor: [Estudiante]
# Fecha: Marzo 2026
# Descripción: Plantilla base de infraestructura AWS usando Terraform (IaC)
# =============================================================================

# -----------------------------------------------------------------------------
# PASO 1: Definición del proveedor AWS
# Se especifica la región donde se desplegarán los recursos.
# -----------------------------------------------------------------------------
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Proyecto    = "Semana8-Taller"
      Entorno     = var.environment
      Gestionado  = "Terraform"
    }
  }
}

# -----------------------------------------------------------------------------
# VARIABLES: Centralización de parámetros configurables
# Buena práctica de IaC: separar configuración de lógica (patrón Externalized Config)
# -----------------------------------------------------------------------------
variable "aws_region" {
  description = "Región de AWS donde se desplegará la infraestructura"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Entorno del despliegue (dev, staging, prod)"
  type        = string
  default     = "dev"
}

variable "vpc_cidr" {
  description = "Bloque CIDR para la VPC principal"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "Bloque CIDR para la subred pública"
  type        = string
  default     = "10.0.1.0/24"
}

variable "private_subnet_cidr" {
  description = "Bloque CIDR para la subred privada"
  type        = string
  default     = "10.0.2.0/24"
}

variable "instance_type" {
  description = "Tipo de instancia EC2"
  type        = string
  default     = "t3.micro"
}

# -----------------------------------------------------------------------------
# RED: VPC, Subredes, Internet Gateway y Tabla de Rutas
# Patrón aplicado: "Network Isolation" – segmentación de red pública/privada
# -----------------------------------------------------------------------------
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "vpc-${var.environment}-main"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "igw-${var.environment}"
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true

  tags = {
    Name = "subnet-${var.environment}-public"
    Tier = "Public"
  }
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidr
  availability_zone = "${var.aws_region}b"

  tags = {
    Name = "subnet-${var.environment}-private"
    Tier = "Private"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "rt-${var.environment}-public"
  }
}

resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# -----------------------------------------------------------------------------
# SEGURIDAD: Security Groups
# Principio de mínimo privilegio (DevSecOps) – solo los puertos necesarios
# -----------------------------------------------------------------------------
resource "aws_security_group" "web_sg" {
  name        = "sg-${var.environment}-web"
  description = "Security Group para servidor web (HTTP/HTTPS + SSH restringido)"
  vpc_id      = aws_vpc.main.id

  # Tráfico entrante HTTP
  ingress {
    description = "HTTP desde cualquier origen"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Tráfico entrante HTTPS
  ingress {
    description = "HTTPS desde cualquier origen"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # SSH restringido – solo desde la VPC interna (buena práctica de seguridad)
  ingress {
    description = "SSH solo desde dentro de la VPC"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # Tráfico saliente sin restricciones
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "sg-${var.environment}-web"
  }
}

# -----------------------------------------------------------------------------
# CÓMPUTO: Instancia EC2 (Servidor Web)
# Patrón aplicado: "Auto Scaling Ready" – AMI parametrizable, tipo escalable
# -----------------------------------------------------------------------------

# Obtener la AMI de Amazon Linux 2023 más reciente de forma dinámica
data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_instance" "web_server" {
  ami                    = data.aws_ami.amazon_linux_2023.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.web_sg.id]

  # Script de inicio: instala y arranca un servidor web (Nginx)
  user_data = <<-EOF
    #!/bin/bash
    dnf update -y
    dnf install -y nginx
    systemctl enable nginx
    systemctl start nginx
    echo "<h1>Infraestructura bajo código – Semana 8 Taller</h1>" \
      > /usr/share/nginx/html/index.html
  EOF

  # Monitoreo detallado habilitado (buena práctica DevOps/observabilidad)
  monitoring = true

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 20
    delete_on_termination = true
    encrypted             = true  # Cifrado en reposo (práctica de seguridad)
  }

  tags = {
    Name = "ec2-${var.environment}-web-server"
  }
}

# -----------------------------------------------------------------------------
# ALMACENAMIENTO: Bucket S3 para activos estáticos
# Patrón aplicado: "Static Content Hosting" / separación de responsabilidades
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "static_assets" {
  bucket = "taller-semana8-${var.environment}-assets-${random_id.suffix.hex}"

  tags = {
    Name    = "s3-${var.environment}-static-assets"
    Uso     = "Activos estáticos"
  }
}

resource "random_id" "suffix" {
  byte_length = 4
}

# Bloqueado todo acceso público (seguridad por defecto)
resource "aws_s3_bucket_public_access_block" "static_assets_block" {
  bucket                  = aws_s3_bucket.static_assets.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Cifrado del bucket en reposo
resource "aws_s3_bucket_server_side_encryption_configuration" "static_assets_sse" {
  bucket = aws_s3_bucket.static_assets.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Versionado habilitado (permite recuperación ante errores – patrón Resilience)
resource "aws_s3_bucket_versioning" "static_assets_versioning" {
  bucket = aws_s3_bucket.static_assets.id

  versioning_configuration {
    status = "Enabled"
  }
}

# -----------------------------------------------------------------------------
# OUTPUTS: Valores exportados tras el despliegue
# Facilitan la integración con otros módulos o pipelines CI/CD (práctica DevOps)
# -----------------------------------------------------------------------------
output "vpc_id" {
  description = "ID de la VPC creada"
  value       = aws_vpc.main.id
}

output "web_server_public_ip" {
  description = "IP pública del servidor web EC2"
  value       = aws_instance.web_server.public_ip
}

output "web_server_public_dns" {
  description = "DNS público del servidor web EC2"
  value       = aws_instance.web_server.public_dns
}

output "s3_bucket_name" {
  description = "Nombre del bucket S3 de activos estáticos"
  value       = aws_s3_bucket.static_assets.bucket
}
