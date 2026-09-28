data "archive_file" "page_views" {
  type        = "zip"
  source_file = "${path.module}/lambda/page_views.py"
  output_path = "${path.module}/lambda/page_views.zip"
}

resource "aws_dynamodb_table" "page_views" {
  name         = "the-drift-log-page-views"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"

  attribute {
    name = "pk"
    type = "S"
  }

  server_side_encryption {
    enabled = true
  }
}

data "aws_iam_policy_document" "page_views_lambda_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type = "Service"

      identifiers = [
        "lambda.amazonaws.com"
      ]
    }

    actions = [
      "sts:AssumeRole"
    ]
  }
}

resource "aws_iam_role" "page_views_lambda" {
  name               = "the-drift-log-page-views-lambda"
  assume_role_policy = data.aws_iam_policy_document.page_views_lambda_assume_role.json
}

resource "aws_iam_role_policy_attachment" "page_views_lambda_basic" {
  role       = aws_iam_role.page_views_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "page_views_dynamodb" {
  statement {
    sid    = "PageViewTableAccess"
    effect = "Allow"

    actions = [
      "dynamodb:BatchGetItem",
      "dynamodb:TransactWriteItems",
      "dynamodb:UpdateItem"
    ]

    resources = [
      aws_dynamodb_table.page_views.arn
    ]
  }
}

resource "aws_iam_role_policy" "page_views_dynamodb" {
  name   = "page-view-dynamodb-access"
  role   = aws_iam_role.page_views_lambda.id
  policy = data.aws_iam_policy_document.page_views_dynamodb.json
}

resource "aws_cloudwatch_log_group" "page_views" {
  name              = "/aws/lambda/the-drift-log-page-views"
  retention_in_days = 14
}

resource "aws_lambda_function" "page_views" {
  function_name = "the-drift-log-page-views"

  role    = aws_iam_role.page_views_lambda.arn
  handler = "page_views.handler"
  runtime = "python3.12"

  architectures = [
    "arm64"
  ]

  filename         = data.archive_file.page_views.output_path
  source_code_hash = data.archive_file.page_views.output_base64sha256

  memory_size = 128
  timeout     = 5

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.page_views.name
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.page_views,
    aws_iam_role_policy_attachment.page_views_lambda_basic,
    aws_iam_role_policy.page_views_dynamodb
  ]
}

resource "aws_apigatewayv2_api" "page_views" {
  name          = "the-drift-log-page-views"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "page_views" {
  api_id = aws_apigatewayv2_api.page_views.id

  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.page_views.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "page_views_get" {
  api_id = aws_apigatewayv2_api.page_views.id

  route_key = "GET /api/views"
  target    = "integrations/${aws_apigatewayv2_integration.page_views.id}"
}

resource "aws_apigatewayv2_route" "page_views_post" {
  api_id = aws_apigatewayv2_api.page_views.id

  route_key = "POST /api/views"
  target    = "integrations/${aws_apigatewayv2_integration.page_views.id}"
}

resource "aws_apigatewayv2_stage" "page_views" {
  api_id = aws_apigatewayv2_api.page_views.id

  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit = 20
    throttling_rate_limit  = 10
  }
}

resource "aws_lambda_permission" "page_views_api_gateway" {
  statement_id  = "AllowApiGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.page_views.function_name
  principal     = "apigateway.amazonaws.com"

  source_arn = "${aws_apigatewayv2_api.page_views.execution_arn}/*/*"
}