resource "aws_lb_target_group" "eks" {
  name     = "eks-tg"
  port     = 80
  protocol = "TCP"
  vpc_id   = var.vpc_id
}

resource "aws_lb_listener" "eks" {
  load_balancer_arn = aws_lb.ecs_eks_nlb.arn
  port              = 8080
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.eks.arn
  }
}
