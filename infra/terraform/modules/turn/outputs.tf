output "public_ip" {
  value = aws_eip.coturn.public_ip
}

output "instance_id" {
  value = aws_instance.coturn.id
}

output "security_group_id" {
  value = aws_security_group.coturn.id
}
