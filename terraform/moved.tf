moved {
  from = aws_instance.web
  to   = module.web.aws_instance.this
}

moved {
  from = aws_security_group.web
  to   = module.web.aws_security_group.this
}
