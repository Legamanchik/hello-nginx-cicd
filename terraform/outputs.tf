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

output "k8s_public_ip" {
  description = "Static IP of the k3s node"
  value       = var.enable_k8s ? aws_eip.k8s[0].public_ip : null
}

output "k8s_app_url" {
  value = var.enable_k8s ? "http://${aws_eip.k8s[0].public_ip}/" : null
}

output "argocd_url" {
  value = var.enable_k8s ? "https://${aws_eip.k8s[0].public_ip}:${var.argocd_nodeport}/" : null
}

output "k8s_ssh_command" {
  value = var.enable_k8s ? "ssh -i ~/.ssh/hello-nginx-deploy ec2-user@${aws_eip.k8s[0].public_ip}" : null
}

output "grafana_url" {
  value = var.enable_k8s ? "http://${aws_eip.k8s[0].public_ip}:${var.grafana_nodeport}/" : null
}
