# Keeps the globally unique storage account name from clashing. Stored in
# state, so it stays the same across applies.
resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

locals {
  # Follows our naming convention, e.g. products-lab-x7k2qm-rg.
  name_prefix = "${var.project}-${var.environment}-${random_string.suffix.result}"

  # Storage account names allow only lowercase letters and digits, 3-24 characters.
  storage_account_name = "${replace(local.name_prefix, "-", "")}st"

  repo_root = abspath("${path.module}/..")

  api_base_url = coalesce(var.api_base_url, "https://${var.function_app_name}.azurewebsites.net/api/")

  # CORS origins must not have the trailing slash the endpoint is reported with.
  web_origin = trimsuffix(azurerm_storage_account.web.primary_web_endpoint, "/")

  # Everything that affects the build output, so the SPA republishes on change.
  app_source_files = sort(setunion(
    fileset(local.repo_root, "src/**"),
    fileset(local.repo_root, "public/**"),
    ["index.html", "package-lock.json", "vite.config.ts"],
  ))
  app_source_hash = sha256(join("", [for f in local.app_source_files : filesha256("${local.repo_root}/${f}")]))
}

resource "azurerm_resource_group" "this" {
  name     = "${local.name_prefix}-rg"
  location = var.location
}

# ---------------------------------------------------------------------------
# Static website hosting
# ---------------------------------------------------------------------------

resource "azurerm_storage_account" "web" {
  name                            = local.storage_account_name
  resource_group_name             = azurerm_resource_group.this.name
  location                        = azurerm_resource_group.this.location
  account_kind                    = "StorageV2"
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
}

resource "azurerm_storage_account_static_website" "web" {
  storage_account_id = azurerm_storage_account.web.id
  index_document     = "index.html"
  # The SPA uses history-mode routing, so unknown paths must serve the app.
  error_404_document = "index.html"
}

# ---------------------------------------------------------------------------
# Monitoring
# ---------------------------------------------------------------------------

resource "azurerm_log_analytics_workspace" "this" {
  name                = "${local.name_prefix}-log"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_application_insights" "web" {
  name                = "${local.name_prefix}-appi"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  workspace_id        = azurerm_log_analytics_workspace.this.id
  application_type    = "web"
}

# ---------------------------------------------------------------------------
# Backend CORS
#
# The Function App is managed outside this configuration, so its CORS list is
# edited with the Azure CLI rather than by owning the resource here.
# ---------------------------------------------------------------------------

resource "terraform_data" "function_app_cors" {
  triggers_replace = {
    subscription_id     = var.subscription_id
    resource_group_name = var.function_app_resource_group_name
    function_app_name   = var.function_app_name
    origin              = local.web_origin
  }

  provisioner "local-exec" {
    command = "az functionapp cors add --subscription ${self.triggers_replace.subscription_id} --resource-group ${self.triggers_replace.resource_group_name} --name ${self.triggers_replace.function_app_name} --allowed-origins ${self.triggers_replace.origin}"
  }

  provisioner "local-exec" {
    when = destroy
    # Don't block a destroy if the Function App has already gone.
    on_failure = continue
    command    = "az functionapp cors remove --subscription ${self.triggers_replace.subscription_id} --resource-group ${self.triggers_replace.resource_group_name} --name ${self.triggers_replace.function_app_name} --allowed-origins ${self.triggers_replace.origin}"
  }
}

# ---------------------------------------------------------------------------
# Build and publish the SPA
#
# Vite bakes VITE_* variables in at build time, so the build has to run after
# the monitoring resources exist, and again whenever their values change.
# ---------------------------------------------------------------------------

resource "terraform_data" "publish_app" {
  triggers_replace = {
    source_hash = local.app_source_hash
    api_url     = local.api_base_url
    # Hashed so the connection string isn't copied into this resource's state.
    app_insights = sha256(azurerm_application_insights.web.connection_string)
    # Recreating the account or website config empties $web.
    website = azurerm_storage_account_static_website.web.id
  }

  provisioner "local-exec" {
    working_dir = local.repo_root
    interpreter = ["bash", "-c"]

    environment = {
      # Process variables take priority over any .env.local file.
      VITE_API_BASE_URL                  = local.api_base_url
      VITE_APPINSIGHTS_CONNECTION_STRING = azurerm_application_insights.web.connection_string
    }

    command = <<-EOT
      set -euo pipefail
      npm ci
      npm run build
      az storage blob upload-batch \
        --subscription ${var.subscription_id} \
        --account-name ${azurerm_storage_account.web.name} \
        --auth-mode key \
        --source ./dist \
        --destination '$web' \
        --overwrite
    EOT
  }
}
