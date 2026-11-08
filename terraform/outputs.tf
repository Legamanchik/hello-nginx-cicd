output "public_ip" {
  description = "Static IP of the test server (GitHub variable DEPLOY_HOST)"
  value       = aws_eip.app.public_ip
}

output "app_url" {
  value = "http://${aws_eip.app.public_ip}/"
}

output "ssh_command" {
  value = "ssh -i ~/.ssh/hello-nginx-deploy ec2-user@${aws_eip.app.public_ip}"
}
