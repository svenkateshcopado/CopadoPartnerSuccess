# Asana-Copado Integration

This repository contains the full source format package for the Asana to Copado CI/CD integration.

## What it does

- Syncs Asana tasks to Copado User Stories (inbound) via webhooks and scheduled batch sync
- Syncs Copado User Story changes back to Asana tasks (outbound)
- Fully configurable via Custom Metadata Types (no code changes needed for new field mappings)
- Supports custom field GID mapping, tag-based filtering, and record type routing

## Package Structure

```
force-app/main/default/
├── classes/                     # All Apex classes
├── objects/
│   ├── Asana_Integration_Settings__c/   # Custom Setting
│   ├── Asana_Field_Mapping__mdt/        # Field mapping CMDT
│   ├── Asana_Record_Type_Mapping__mdt/  # Record type routing CMDT
│   └── copado__User_Story__c/           # External ID field
└── customMetadata/              # Pre-configured CMDT records
```

## Setup Steps

1. **Deploy** this package to your org:
   ```bash
   sf project deploy start --source-dir force-app --target-org your-org-alias
   ```

2. **Create a Named Credential** called `AsanaCopado`:
   - URL: `https://app.asana.com`
   - Auth: No Authentication (PAT sent via header)

3. **Create a Salesforce Site** called `AsanaIntegration`:
   - Grant guest user access to `AsanaWebhookEndpoint` Apex class

4. **Configure the Custom Setting**:
   - Setup > Custom Settings > Asana Integration Settings > Manage > New
   - Set your Asana PAT and Project GID

5. **Update CMDT records** with your Asana enum GIDs:
   - Setup > Custom Metadata Types > Asana Field Mapping > Manage Records
   - Update `Completion_status` Value Map with real GIDs

6. **Register the webhook** (run once in Anonymous Apex):
   ```apex
   AsanaWebhookRegistration.registerWebhook();
   ```

7. **Run a diagnostic** to verify the setup:
   ```apex
   AsanaDiagnostic.runAsync();
   ```

## Key Classes

| Class | Purpose |
|---|---|
| `AsanaWebhookEndpoint` | REST endpoint receiving Asana webhook events |
| `AsanaWebhookQueueable` | Queueable wrapper for async processing |
| `AsanaWebhookProcessor` | Inbound: Asana task to Copado User Story |
| `AsanaOutboundSync` | Outbound: Copado User Story to Asana task |
| `AsanaTaskSync` | Batch/scheduled full sync from Asana project |
| `AsanaSyncScheduler` | Schedulable wrapper |
| `AsanaWebhookRegistration` | One-time webhook registration |
| `AsanaDiagnostic` | Full integration health check |
