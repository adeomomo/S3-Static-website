resource "aws_s3_bucket" "website_bucket" {
  bucket        = "adeomomo-aws-project-website"
  force_destroy = true
}

# S3 Public Access Block - adjust settings required for public static hosting
resource "aws_s3_bucket_public_access_block" "website_block" {
  bucket                  = aws_s3_bucket.website_bucket.id
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

# Bucket Policy to allow public read access to website files
resource "aws_s3_bucket_policy" "website_policy" {
  depends_on = [aws_s3_bucket_public_access_block.website_block]
  bucket     = aws_s3_bucket.website_bucket.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "PublicReadGetObject"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.website_bucket.arn}/*"
      },
    ]
  })
}

# S3 Website Configuration
resource "aws_s3_bucket_website_configuration" "website_config" {
  bucket = aws_s3_bucket.website_bucket.id

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "error.html"
  }
}

# Output the website endpoint
output "website_endpoint" {
  value       = aws_s3_bucket_website_configuration.website_config.website_endpoint
  description = "The public endpoint of the static website."
}
