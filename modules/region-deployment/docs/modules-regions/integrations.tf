locals {
  integration_uris = {
    "AWS_PROXY" = { 
      type = "AWS_PROXY", 
      uri_format = "arn:aws:apigateway:%s:lambda:path/2015-03-31/functions/%s/invocations" 
    },
    "ECS_PROXY" = {
      type = "HTTP_PROXY",
      uri_format = "http://%s/v1/{proxy}"
    },
    "EKS_PROXY" = {
      type = "HTTP_PROXY", 
      uri_format = "http://%s/api/v1/{proxy}"
    }
  }
}

resource "aws_api_gateway_integration" "dynamic" {
  for_each = { for idx, method in local.all_methods : idx => method }

  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.resource[each.value.resource_path].id
  http_method = each.value.http_method

  type                    = local.integration_uris[each.value.integration_type].type
  integration_http_method = each.value.integration_type == "AWS_PROXY" ? "POST" : "ANY"
  uri = format(
    local.integration_uris[each.value.integration_type].uri_format,
    var.region,
    lookup(var.backend_services.lambda_arns, each.value.service_name, 
           lookup(var.backend_services.ecs_arns, each.value.service_name,
                  lookup(var.backend_services.eks_arns, each.value.service_name, "")))
  connection_type = contains(["ECS_PROXY", "EKS_PROXY"], each.value.integration_type) ? "VPC_LINK" : "INTERNET"
  connection_id   = contains(["ECS_PROXY", "EKS_PROXY"], each.value.integration_type) ? aws_api_gateway_vpc_link.nlb_link.id : null

  request_parameters = merge(
    each.value.request_parameters,
    { "integration.request.path.proxy" = "method.request.path.proxy" }
  )
}


# modules/member-zone/main.tf
resource "aws_api_gateway_resource" "nested" {
  for_each = { 
    for path in distinct(flatten([
      for r in var.api_config.resources : [
        for part in split("/", r.path) : {
          path = join("/", [for p in split("/", r.path)[0:index(split("/", r.path), part)+1] : p])
          parent = length(split("/", r.path)[0:index(split("/", r.path), part)]) > 0 ? 
                   join("/", split("/", r.path)[0:index(split("/", r.path), part)]) : ""
        }
      ]
    ])) : path.path => path
  }

  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = each.value.parent != "" ? aws_api_gateway_resource.nested[each.value.parent].id : aws_api_gateway_rest_api.main.root_resource_id
  path_part   = contains(split("/", each.key), "{") ? 
                element(split("/", each.key), length(split("/", each.key))-1) : 
                element(split("/", each.key), -1)
}





# modules/member-zone/main.tf
resource "aws_api_gateway_method" "parameterized" {
  for_each = { 
    for method in local.all_methods : 
    "${method.resource_path}_${method.http_method}" => method 
    if length(regexall("{([^}]+)}", method.resource_path)) > 0
  }

  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.nested[each.value.resource_path].id
  http_method   = each.value.http_method
  authorization = "NONE"

  request_parameters = merge(
    { for param in regexall("{([^}]+)}", each.value.resource_path) : 
      "method.request.path.${param[0]}" => true
    },
    each.value.request_parameters
  )
}






# In root main.tf
module "member_zone" {
  # ... other vars ...

  backend_services = {
    lambda_arns = {
      "credit-report-lambda" = "arn:aws:lambda:us-east-1:123456789012:function:credit-report"
    },
    ecs_arns = {
      "data-service" = "arn:aws:ecs:us-east-1:123456789012:service/cluster-name/service-name"
    },
    eks_arns = {
      "loan-service" = "k8s-cluster-name.example.com"
    }
  }
}






