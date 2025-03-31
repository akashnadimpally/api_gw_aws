resource "aws_api_gateway_vpc_link" "main" {
  name        = "ecs-vpc-link"
  target_arns = [aws_lb.ecs_eks_nlb.arn]
}

resource "aws_lb" "ecs_eks_nlb" {
  name               = "ecs-eks-nlb"
  internal           = true
  load_balancer_type = "network"
  subnets            = var.private_subnets
}

resource "aws_lb_target_group" "ecs" {
  name     = "ecs-tg"
  port     = 80
  protocol = "TCP"
  vpc_id   = var.vpc_id
}

resource "aws_lb_listener" "ecs" {
  load_balancer_arn = aws_lb.ecs_eks_nlb.arn
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ecs.arn
  }
}
