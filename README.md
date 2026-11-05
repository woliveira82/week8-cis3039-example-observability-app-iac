# Observable Frontend App Example

## Local Setup

```bash
npm install
```

### Compile and Hot-Reload for Development

```bash
npm run dev
```

### Type-Check, Compile and Minify for Production

```bash
npm run build
```

## Azure Setup

The Azure resources are defined with Terraform in [infra/](infra/README.md). A single `terraform apply` creates them, builds the SPA with the right settings and publishes it to the storage account's static website.

### Prerequisites

- The backend products Function App, deployed separately. This repo doesn't create it, but it does add the deployed site to the app's CORS settings, so the app must exist before you apply.
- Terraform 1.5 or later.
- The Azure CLI, logged in with `az login`.
- Node.js `^20.19.0` or `>=22.12.0`.
- An Azure account that can create resource groups, in a subscription where `Microsoft.Storage`, `Microsoft.OperationalInsights` and `Microsoft.Insights` are registered.

### Deploy

1. Create your settings file:

```bash
cd infra
cp terraform.tfvars.example terraform.tfvars
```

2. Edit `terraform.tfvars`:

| Setting | Value |
| --- | --- |
| `subscription_id` | Your Azure subscription ID |
| `project` | Project name used in resource names, up to 10 characters |
| `environment` | Environment name used in resource names, up to 6 characters, such as `lab` |
| `location` | An Azure region your subscription permits |
| `function_app_name` | The name of your backend Function App |
| `function_app_resource_group_name` | The resource group containing your backend Function App |
| `api_base_url` | Optional. Set this only if your Function App doesn't use `<name>.azurewebsites.net`, and include the trailing slash |

3. Create the resources and publish the app:

```bash
terraform init
terraform apply
```

4. Get the URL of the deployed site:

```bash
terraform output website_url
```

### Publish changes

Run `terraform apply` from `infra/` again. Because SPAs bake their environment variables in at build time, it rebuilds and republishes the app whenever the source files or its settings change.

To republish when nothing has changed:

```bash
terraform apply -replace=terraform_data.publish_app
```

### Send local telemetry to Application Insights

Get the connection string from `infra/`:

```bash
terraform output -raw application_insights_connection_string
```

Assign it to the `VITE_APPINSIGHTS_CONNECTION_STRING` env var in your `.env.local`.

### Remove the resources

```bash
terraform destroy
```

This deletes everything Terraform created and removes the site from the Function App's CORS settings. The Function App itself isn't deleted.

## Azure Application Insights Telemetry Setup

This application has been configured with Azure Application Insights for comprehensive telemetry tracking.

- **`useTelemetry`**: A Vue composable in `src/composables/useTelemetry.ts` that directly wraps Azure Application Insights
  - Initializes App Insights on first use
  - Returns helper functions for tracking events, exceptions, dependencies, metrics, and page views
  - Handles missing configuration gracefully

The telemetry composable is used throughout the application:

```typescript
import { useTelemetry } from '@/composables/useTelemetry';

const {
  trackEvent,
  trackException,
  trackDependency,
  trackMetric,
  trackPageView,
} = useTelemetry();

// Track events
trackEvent('UserAction', { details: 'value' });

// Track exceptions
trackException(error, { context: 'componentName' });

// Track dependencies (API calls)
trackDependency('API Call', url, duration, success, statusCode);

// Track metrics
trackMetric('MetricName', value);

// Track page views
trackPageView('PageName', url);
```

## How the project was made

```bash
npm create vue@3 . -- \
  --force \
  --bare \
  --typescript \
  --router \
  --prettier
```

Restore any delete devcontainer configuration:

```bash
git restore .devcontainer/devcontainer.json
```

Add extensions to devcontainer:

- `"esbenp.prettier-vscode"`,
- `"Vue.volar"`

Update preferences in `.prettierrc.json`:

- `"semi": true`
- `"singleQuote": true`
- `"printWidth": 80`
