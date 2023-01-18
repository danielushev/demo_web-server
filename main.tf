#Create key pair
resource "tls_private_key" "webserver_private_key" {
 algorithm = "RSA"
 rsa_bits = 4096
}
resource "local_file" "private_key" {
 content = tls_private_key.webserver_private_key.private_key_pem
 filename = "webserver_key.pem"
# set permissions if used on linux
# file_permission = 0400
}
resource "aws_key_pair" "webserver_key" {
 key_name = "webserver"
 public_key = tls_private_key.webserver_private_key.public_key_openssh
}

# #Create security group
resource "aws_security_group" "demo_allow_http_ssh" {
  name        = "demo_allow_http"
  description = "Allow specific inbound traffic"
ingress {
    description = "http"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] 
  }
ingress {
    description = "EFS mount target"
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }  
ingress {
    description = "ssh"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
   } 
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "all"
    cidr_blocks = ["0.0.0.0/0"]
  }
tags = {
    Name = "allow_http_ssh"
  }
}

#Create security group for the DB
resource "aws_security_group" "demo_db_sg" {
  name        = "demo_db_sg"
  description = "Allow internal traffic to the db"
ingress {
    description = "Allow internal traffic to the db"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    security_groups = [aws_security_group.demo_allow_http_ssh.id]
  }
}

#Create EC2 machine
resource "aws_instance" "webserver" {
  ami           = "ami-0a261c0e5f51090b1"
  instance_type = "t2.micro" 
  key_name  = aws_key_pair.webserver_key.key_name
  security_groups=[aws_security_group.demo_allow_http_ssh.name]
tags = {
    Name = "webserver"
  }
  connection {
        type    = "ssh"
        user    = "ec2-user"
        host    = aws_instance.webserver.public_ip
        port    = 22
        private_key = tls_private_key.webserver_private_key.private_key_pem
    }
}


# Create EFS
resource "aws_efs_file_system" "efs" {
  creation_token = "dani_efs"
  tags = {
    Name = "dani_efs"
  }
}
resource "aws_efs_mount_target" "mount" {
  file_system_id = aws_efs_file_system.efs.id
  subnet_id      = aws_instance.webserver.subnet_id
  security_groups = [aws_security_group.demo_allow_http_ssh.id]

}
resource "null_resource" "configure_nfs" {
  depends_on = [aws_efs_mount_target.mount]
   connection {
    type     = "ssh"
    user     = "ec2-user"
    private_key = tls_private_key.webserver_private_key.private_key_pem
    host     = aws_instance.webserver.public_ip
   }
  provisioner "remote-exec" {
    inline = [
      "sudo yum install httpd php git -y -q ",
      "sudo systemctl start httpd",
      "sudo systemctl enable httpd",
      "sudo yum -y install nfs-utils",
      "sudo mount -t nfs -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport ${aws_efs_file_system.efs.dns_name}:/  /var/www/html",
      "echo ${aws_efs_file_system.efs.dns_name}:/ /var/www/html nfs4 defaults,_netdev 0 0  | sudo cat >> /etc/fstab " ,
      "sudo chmod go+rw /var/www/html",
      "sudo git clone https://github.com/danielushev/demo_php_app /var/www/html",
    ]
  }
}


# Create ELB
resource "aws_elb" "demo-elb" {
  name               = "demo-elb"
  availability_zones = ["eu-central-1a"]
  security_groups = [aws_security_group.demo_allow_http_ssh.id]

  listener {
    instance_port     = 80
    instance_protocol = "http"
    lb_port           = 80
    lb_protocol       = "http"
  }
  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 5
    timeout             = 10
    target              = "HTTP:80/"
    interval            = 30
  }
  instances                   = [aws_instance.webserver.id]
  cross_zone_load_balancing   = false
  idle_timeout                = 400
  connection_draining         = true
  connection_draining_timeout = 400
  tags = {
    Name = "demo_elb"
  }
}


#Create RDS
resource "aws_db_instance" "dani-db" {
  allocated_storage    = 10
  identifier           = "dani-db"
  engine               = "postgres"
  instance_class       = "db.t3.micro"
  username             = "daniel"
  password             = "147369159d"
  vpc_security_group_ids = [aws_security_group.demo_db_sg.id]
  skip_final_snapshot = true
}


#Create CloudWatch alert
resource "aws_cloudwatch_metric_alarm" "dani_alarm" {
  alarm_name                = "dani_alarm"
  comparison_operator       = "GreaterThanOrEqualToThreshold"
  evaluation_periods        = "2"
  metric_name               = "RequestCount"
  namespace                 = "AWS/ELB"
  period                    = "60"
  statistic                 = "Sum"
  threshold                 = "1"
  alarm_description         = "This metric monitors the number of requests"
  dimensions = {
    LoadBalancerName = "demo-elb"
}
}

# #Create Ami from EC2
# resource "aws_ami_from_instance" "autoscale_ami" {
#   name               = "autoscale_ami"
#   source_instance_id = aws_instance.webserver.id
# }

# #Set up autoscaling

# #Create launch configuration template
# resource "aws_launch_configuration" "webservers" {
#   name   = "webservers_launch_config"
#   image_id      = aws_ami_from_instance.autoscale_ami.id
#   instance_type = "t2.micro"
#   security_groups  = [aws_security_group.demo_allow_http_ssh.id]
#   key_name  = aws_key_pair.webserver_key.key_name
# }

# #Create the autoscaling group
# resource "aws_autoscaling_group" "webservers" {
#   availability_zones = ["eu-central-1a"]
#   desired_capacity   = 1
#   max_size           = 3
#   min_size           = 0
#   launch_configuration = aws_launch_configuration.webservers.name
#   lifecycle {
#     create_before_destroy = true
#   }
# }

# #Create an AWS AutoScaling policy
# resource "aws_autoscaling_policy" "simple_scaling" {
#   name                   = "simple_scaling_policy"
#   scaling_adjustment     = 3
#   policy_type            = "SimpleScaling"
#   adjustment_type        = "ChangeInCapacity"
#   cooldown               = 100
#   autoscaling_group_name = aws_autoscaling_group.webservers.name
# }

# #Create an AWS AutoScaling schedule
# resource "aws_autoscaling_schedule" "server_autoscaling_schedule" {
#   scheduled_action_name  = "server_autoscaling_schedule"
#   min_size               = 0
#   max_size               = 3
#   desired_capacity       = 1
#   start_time             = "2023-01-20T18:00:00Z"
#   end_time               = "2023-01-22T06:00:00Z"
#   autoscaling_group_name = aws_autoscaling_group.webservers.name
# }

# #Create an AutoScaling group notification
# resource "aws_autoscaling_notification" "webserver_asg_notifications" {
#   group_names = [
#     aws_autoscaling_group.webservers.name,
#   ]
#   notifications = [
#     "autoscaling:EC2_INSTANCE_LAUNCH",
#     "autoscaling:EC2_INSTANCE_TERMINATE",
#     "autoscaling:EC2_INSTANCE_LAUNCH_ERROR",
#     "autoscaling:EC2_INSTANCE_TERMINATE_ERROR",
#   ]
#   topic_arn = aws_sns_topic.webserver_topic.arn
# }
# resource "aws_sns_topic" "webserver_topic" {
#   name = "webserver_topic"
# }

# #Create an AutoScaling attachment to ELB
# resource "aws_autoscaling_attachment" "webservers_asg_attachment" {
#   autoscaling_group_name = aws_autoscaling_group.webservers.id
#   elb                    = aws_elb.demo-elb.id
# }

