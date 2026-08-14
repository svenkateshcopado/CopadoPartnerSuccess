# Asana - Copado Integration
## Full Solution Documentation

> **Repository:** `svenkateshcopado/CopadoPartnerSuccess`
> **Branch:** `main`
> **Last Updated:** August 14, 2026

---

## Table of Contents

1. [Solution Overview](#1-solution-overview)
2. [Architecture Diagram](#2-architecture-diagram)
3. [Metadata Components](#3-metadata-components)
   - 3.1 Custom Setting
   - 3.2 Custom Metadata Types
   - 3.3 Custom Field on User Story
   - 3.4 Apex Classes
4. [Sync Flows Explained](#4-sync-flows-explained)
   - 4.1 Inbound: Asana to Copado (Real-time via Webhook)
   - 4.2 Inbound: Asana to Copado (Bulk via Scheduled Sync)
   - 4.3 Outbound: Copado to Asana
5. [Field Mapping System](#5-field-mapping-system)
6. [Record Type Mapping System](#6-record-type-mapping-system)
7. [Filtering System](#7-filtering-system)
8. [Error Handling and Resilience](#8-error-handling-and-resilience)
9. [Configuration Reference](#9-configuration-reference)
10. [Deployment Guide](#10-deployment-guide)
11. [Post-Deployment Checklist](#11-post-deployment-checklist)
12. [Troubleshooting](#12-troubleshooting)

---

## 1. Solution Overview

This solution creates a **bidirectional, real-time sync** between Asana tasks and Copado User Stories inside a Salesforce org. It is fully configuration-driven, meaning no code changes are needed to add or modify field mappings, field types, value translations, or record type rules. Everything is controlled through Custom Metadata records.

### Key Capabilities

| Capability | Description |
|---|---|
| Real-time inbound sync | Asana tasks are pushed to Salesforce instantly via webhooks |
| Bulk inbound sync | All tasks in an Asana project are pulled on demand or on a schedule |
| Outbound sync | Changes made to Copado User Stories are pushed back to Asana |
| Field value translation | Asana enum GIDs are translated to Copado picklist labels (and vice versa) |
| Record type mapping | Asana task subtypes and tags determine the Copado User Story record type |
| Task filtering | Only tasks matching a specific tag or custom field value are synced |
| Diagnostic tooling | One-click diagnostic class validates the entire setup end to end |
| Zero hard-coded field maps | All mappings live in Custom Metadata, deployable across orgs |

---

## 2. Architecture Diagram

```
+---------------------------------------------------------------------+
|                          ASANA                                      |
|                                                                     |
|   Project --> Tasks --> Custom Fields / Tags / Subtypes             |
|                  |                                                  |
|         Webhook Events (task added / changed)                       |
+------------------+--------------------------------------------------+
                   |  HTTPS POST  (X-Hook-Secret handshake on first call)
                   v
+---------------------------------------------------------------------+
|                     SALESFORCE SITE (Guest User)                    |
|                                                                     |
|              AsanaWebhookEndpoint  (@RestResource)                  |
|              /asana/webhook/*                                       |
|                   |                                                 |
|          Extracts task GIDs from event payload                      |
|                   |                                                 |
|          Enqueues one AsanaWebhookQueueable per task GID            |
+------------------+--------------------------------------------------+
                   |  System.enqueueJob()
                   v
+---------------------------------------------------------------------+
|                  AsanaWebhookQueueable (Queueable)                  |
|                                                                     |
|  Allows callouts from async context. Calls AsanaWebhookProcessor.   |
+------------------+--------------------------------------------------+
                   |
                   v
+---------------------------------------------------------------------+
|               AsanaWebhookProcessor  (Core Inbound Engine)          |
|                                                                     |
|  1. Reads Asana Integration Settings (PAT, filters)                 |
|  2. Reads active Inbound Field Mappings from CMDT                   |
|  3. Reads Record Type Mappings from CMDT                            |
|  4. Calls Asana API: GET /tasks/{gid}?opt_fields=...               |
|  5. Applies tag/custom field filters                                |
|  6. Resolves Copado Record Type from tags / resource_subtype        |
|  7. Translates field values using Value_Map JSON                    |
|  8. Upserts copado__User_Story__c via Asana_Task_Id__c (ext ID)    |
+---------------------------------------------------------------------+

                   ^ (Outbound direction, triggered by Flow/Trigger)
                   |
+---------------------------------------------------------------------+
|               AsanaOutboundSync  (Core Outbound Engine)             |
|                                                                     |
|  1. Reads active Outbound Field Mappings from CMDT                  |
|  2. Queries Copado User Story fields dynamically                    |
|  3. Reverse-translates values (Copado label -> Asana GID)           |
|  4. Calls Asana API: PUT /tasks/{asanaTaskId}                       |
+---------------------------------------------------------------------+

                   (Bulk / Scheduled direction)
+---------------------------------------------------------------------+
|               AsanaTaskSync  (Bulk Inbound Engine)                  |
|                                                                     |
|  1. Calls Asana API: GET /projects/{gid}/tasks?opt_fields=...      |
|  2. Applies same filters and field mapping logic as webhook path    |
|  3. Bulk-upserts all matching User Stories                          |
|                                                                     |
|  Invocable from: Flow, Scheduled Job (AsanaSyncScheduler)           |
+---------------------------------------------------------------------+
```

---

## 3. Metadata Components

### 3.1 Custom Setting: `Asana_Integration_Settings__c`

**Type:** Hierarchy Custom Setting
**Purpose:** Stores org-wide configuration for the integration. All sensitive and environment-specific values live here so they never need to be hard-coded or committed to source control.

| Field | API Name | Type | Purpose |
|---|---|---|---|
| Asana PAT | `Asana_PAT__c` | Text(255) | Personal Access Token to authenticate Asana API calls |
| Asana Project GID | `Asana_Project_GID__c` | Text(50) | The GID of the Asana project to sync with |
| Filter By Tag | `Filter_By_Tag__c` | Text(100) | Only sync tasks that have this exact tag name |
| Filter Custom Field Name | `Filter_Custom_Field_Name__c` | Text(100) | Only sync tasks where this custom field... |
| Filter Custom Field Value | `Filter_Custom_Field_Value__c` | Text(100) | ...equals this value (paired with above) |
| Webhook GID | `Webhook_GID__c` | Text(50) | Auto-populated by AsanaWebhookRegistration after registration |
| Webhook Secret | `Webhook_Secret__c` | Text(255) | Auto-populated on first Asana handshake (X-Hook-Secret) |

---

### 3.2 Custom Metadata Types

#### `Asana_Field_Mapping__mdt` — Field-level mapping configuration

**Purpose:** Defines which Asana field maps to which Copado User Story field, in which direction, and how values should be translated.

| Field | API Name | Purpose |
|---|---|---|
| Asana Field API Name | `Asana_Field_API_Name__c` | Asana field key (e.g. `name`, `notes`) or a numeric custom field GID |
| Copado Field API Name | `Copado_Field_API_Name__c` | Salesforce field API name on `copado__User_Story__c` |
| Direction | `Direction__c` | `Both`, `Inbound`, or `Outbound` |
| Field Type | `Field_Type__c` | `Text`, `Boolean`, `Number`, or `Date` |
| Is Active | `Is_Active__c` | Toggle this to disable a mapping without deleting it |
| Value Map (JSON) | `Value_Map__c` | JSON object translating Asana values to Copado values (inbound) or vice versa (outbound) |

**Pre-configured records shipped with the package:**

| Record Label | Asana Field | Copado Field | Direction | Notes |
|---|---|---|---|---|
| Title Mapping | `name` | `copado__User_Story_Title__c` | Both | Plain text, no translation needed |
| Description | `notes` | `copado__Technical_Specifications__c` | Both | Plain text, no translation needed |
| Completion status | Custom field GID | `copado__Status__c` | Both | Requires your Asana enum GIDs in Value_Map. This is the single source of truth for status sync |

> **Note:** Status sync is handled exclusively by the `Completion status` record using Asana's custom field GID and a JSON value map. This correctly translates rich Copado status picklist values to and from Asana enum options in both directions.

---

#### `Asana_Record_Type_Mapping__mdt` — Record type resolution

**Purpose:** Determines which Copado User Story record type to assign based on the Asana task's resource subtype or its tags.

| Field | API Name | Purpose |
|---|---|---|
| Asana Task Value | `Asana_Task_Value__c` | Tag name or resource subtype (e.g. `bug`, `milestone`, `default_task`) |
| Copado Record Type Developer Name | `Copado_Record_Type_Developer_Name__c` | Developer name of the target RecordType on User Story |
| Is Active | `Is_Active__c` | Toggle to disable |
| Is Default | `Is_Default__c` | Fallback record type when no tag/subtype matches |

**Pre-configured records:**

| Record | Asana Value | Copado Record Type | Is Default |
|---|---|---|---|
| Default Task Mapping | `default_task` | `User_Story` | Yes |
| Milestone Mapping | `milestone` | `User_Story` | No |
| Bug Tag Mapping | `bug` | `Bug` | No |

---

### 3.3 Custom Field: `Asana_Task_Id__c` on `copado__User_Story__c`

**Type:** Text(50), External ID, Unique
**Purpose:** This is the bridge between systems. It stores the Asana task GID on the Copado User Story. All upserts use this field as the external ID key, which means:
- If a User Story with that GID exists, it gets updated.
- If not, a new User Story is created.
- This prevents duplicates across webhook deliveries and bulk syncs.

---

### 3.4 Apex Classes

#### `AsanaWebhookEndpoint`
**Type:** `@RestResource` global class
**URL:** `/asana/webhook/*`
**Purpose:** The public-facing HTTP endpoint that Asana calls when tasks are created or changed.

**Responsibilities:**
- Handles the Asana handshake: on the first call Asana sends an `X-Hook-Secret` header. The class saves this secret to the Custom Setting and echoes it back to Asana to confirm the webhook.
- On subsequent calls, parses the event payload, extracts all task GIDs from task events, ignores `removed` and `deleted` actions, and enqueues one `AsanaWebhookQueueable` per task GID.
- Returns HTTP 200 immediately so Asana does not retry.

---

#### `AsanaWebhookQueueable`
**Type:** `Queueable`, `Database.AllowsCallouts`
**Purpose:** A thin async wrapper. Salesforce does not allow HTTP callouts directly from a synchronous REST context. This class bridges that gap by running the actual API call in an async queue job.

---

#### `AsanaWebhookProcessor`
**Type:** Regular Apex class (called from Queueable)
**Purpose:** The core inbound sync engine. Handles everything for a single Asana task.

**Step-by-step flow:**
1. Reads the PAT and filter settings from the Custom Setting.
2. Queries all active Inbound or Both field mappings from CMDT.
3. Queries all active record type mappings from CMDT.
4. Builds a dynamic `opt_fields` string so only needed Asana fields are returned by the API.
5. Calls `GET /api/1.0/tasks/{gid}` with the PAT in the Authorization header.
6. Applies the tag filter: skips the task if the required tag is not present.
7. Applies the custom field filter: skips the task if the named field does not match the expected value.
8. Resolves the Copado record type by checking tags first, then `resource_subtype`, then falling back to the default.
9. Iterates each field mapping. For custom field GIDs (numeric), it digs into the `custom_fields` array. For standard fields, it reads directly from the task JSON.
10. If a `Value_Map__c` JSON is present, it translates the Asana enum GID to the Copado picklist label. Otherwise it casts the value to the correct field type.
11. Upserts the `copado__User_Story__c` record using `Asana_Task_Id__c` as the external ID.

---

#### `AsanaOutboundSync`
**Type:** Regular Apex class with `@future(callout=true)`
**Purpose:** The core outbound sync engine. Pushes Copado User Story changes back to Asana.

**Step-by-step flow:**
1. Reads the Asana PAT.
2. Queries all active Outbound or Both field mappings.
3. Dynamically builds a SOQL query to fetch only the needed User Story fields.
4. For each mapped field, reverse-translates the value: Copado label goes back to the Asana GID using the same `Value_Map__c` JSON, but in reverse.
5. Separates standard Asana fields from custom field GID fields (numeric keys go into a `custom_fields` sub-object).
6. Calls `PUT /api/1.0/tasks/{asanaTaskId}` with the payload.

**How to trigger it:** Call `AsanaOutboundSync.updateAsanaTask(asanaTaskId, userStoryId)` from a Flow or trigger on `copado__User_Story__c`.

---

#### `AsanaTaskSync`
**Type:** Regular Apex class with `@InvocableMethod` and `@future(callout=true)`
**Purpose:** Bulk inbound sync. Pulls all tasks from the configured Asana project and upserts them as User Stories.

**When to use:**
- First-time setup: import all existing Asana tasks.
- Catch-up run: re-sync after a period of downtime.
- Can be called from a Salesforce Flow (InvocableMethod) for admin-triggered syncs.

---

#### `AsanaSyncScheduler`
**Type:** `Schedulable`
**Purpose:** Runs the bulk sync on a schedule. Invokes the `Asana_To_Copado_Sync` Flow, which in turn calls `AsanaTaskSync`.

**To schedule (run in Anonymous Apex):**
```apex
System.schedule('Asana Daily Sync', '0 0 2 * * ?', new AsanaSyncScheduler());
```
This runs every day at 2:00 AM.

---

#### `AsanaWebhookRegistration`
**Type:** Regular Apex class (run once via Anonymous Apex)
**Purpose:** Registers the Salesforce Site URL as a webhook target with the Asana API. After successful registration, saves the returned webhook GID to the Custom Setting.

**Run once:**
```apex
AsanaWebhookRegistration.registerWebhook();
```
Before running, update the `targetUrl` variable in the class body with your actual Site URL.

---

#### `AsanaDiagnostic`
**Type:** Regular Apex class with `@InvocableMethod` and `@future(callout=true)`
**Purpose:** Full health check of the integration. Run this any time after setup or when something seems wrong.

**What it checks:**
- PAT is configured.
- Project GID is configured.
- Active field mappings are loaded and logged.
- Record type mappings are loaded and matched to actual RecordType records.
- Makes a live test call to the Asana API and reports the HTTP status and number of tasks returned.

**How to run:**
```apex
AsanaDiagnostic.runAsync();
```
Then check the debug logs.

---

#### `AsanaWebhookEndpointTest` and `AsanaWebhookProcessorTest`
**Type:** `@isTest` classes
**Purpose:** Apex unit test coverage. Covers webhook handshake, task event parsing, field type mapping, value map translation, record type resolution, filter logic, and error paths. Combined coverage is 88%+ across all classes.

---

## 4. Sync Flows Explained

### 4.1 Inbound: Real-time via Webhook

```
Asana Task Created/Changed
        |
        v
Asana sends POST to Salesforce Site URL
(/asana/webhook/*)
        |
        v
AsanaWebhookEndpoint receives request
  +- If X-Hook-Secret header present:
  |    Save secret to Custom Setting
  |    Echo header back --> Asana confirms webhook
  |    Return 200
  +- Else:
       Parse events array
       Extract task GIDs (skip removed/deleted)
       Enqueue AsanaWebhookQueueable for each GID
       Return 200 immediately
        |
        v
AsanaWebhookQueueable.execute()
  +- Calls AsanaWebhookProcessor.processTaskEvent(gid)
        |
        v
AsanaWebhookProcessor
  1. Get settings + mappings
  2. Call GET /tasks/{gid} (with opt_fields)
  3. Apply tag filter --> skip if no match
  4. Apply custom field filter --> skip if no match
  5. Resolve record type (tags --> subtype --> default)
  6. Map + translate all fields
  7. Upsert User Story (external ID: Asana_Task_Id__c)
```

### 4.2 Inbound: Bulk via Scheduled Sync

```
Schedule fires (or admin triggers from Flow)
        |
        v
AsanaSyncScheduler.execute()
  +- Starts Asana_To_Copado_Sync Flow
        |
        v
Flow calls AsanaTaskSync (InvocableMethod)
        |
        v
AsanaTaskSync.doSync()
  1. GET /projects/{gid}/tasks?opt_fields=...
  2. Loop each task
     +- Apply tag filter
     +- Apply custom field filter
     +- Resolve record type
     +- Build User Story with mapped fields
  3. Bulk upsert all matching stories
```

### 4.3 Outbound: Copado to Asana

```
User edits Copado User Story
        |
        v
Flow or Trigger fires
  +- Calls AsanaOutboundSync.updateAsanaTask(
         asanaTaskId, userStoryId)
        |
        v (@future callout)
AsanaOutboundSync
  1. Get PAT
  2. Query Outbound/Both field mappings
  3. Dynamic SOQL to get User Story fields
  4. Reverse-translate values (Copado --> Asana)
  5. Separate standard fields vs. custom field GIDs
  6. PUT /tasks/{asanaTaskId} with payload
```

---

## 5. Field Mapping System

The field mapping system is entirely driven by `Asana_Field_Mapping__mdt` records. No code changes are needed to add new fields.

### Standard Asana Fields (text key)
Fields like `name` and `notes` are mapped by their Asana API key name.

```
Asana_Field_API_Name__c  = "name"
Copado_Field_API_Name__c = "copado__User_Story_Title__c"
Field_Type__c            = "Text"
Direction__c             = "Both"
Value_Map__c             = null
```

### Asana Custom Fields (numeric GID)
When `Asana_Field_API_Name__c` is a numeric string (e.g. `1234567890123456`), the processor knows it is a custom field GID and looks it up in the `custom_fields` array of the task response. This is how status sync works via the `Completion status` mapping record.

### Value Map (JSON Translation)
The `Value_Map__c` field accepts a JSON object where keys are Asana values and values are Copado labels (for inbound). On outbound, the map is automatically reversed.

**Example (Completion status):**
```json
{
  "ENUM_GID_NOT_STARTED": "Not started",
  "ENUM_GID_IN_PROGRESS": "In progress",
  "ENUM_GID_COMPLETED":   "Completed"
}
```

**Inbound:** Asana sends `ENUM_GID_IN_PROGRESS` --> Copado stores `In progress`
**Outbound:** Copado has `In progress` --> Asana receives `ENUM_GID_IN_PROGRESS`

### Adding a New Field Mapping
1. Go to Setup > Custom Metadata Types > Asana Field Mapping > Manage Records.
2. Click New.
3. Fill in the fields described above.
4. Set Is Active to true.
5. No deployment needed. Changes take effect on the next sync.

---

## 6. Record Type Mapping System

The processor resolves the Copado User Story record type in priority order:

**Priority 1: Task Tags**
If the task has a tag whose name (lowercase) matches an `Asana_Task_Value__c` in an active, non-default mapping, that record type is used.

**Priority 2: Resource Subtype**
If no tag matches, the task's `resource_subtype` (e.g. `milestone`, `default_task`) is checked against the same mappings.

**Priority 3: Default**
If nothing matches, the mapping with `Is_Default__c = true` is used.

---

## 7. Filtering System

Both sync paths (webhook and bulk) apply the same two optional filters from the Custom Setting before any record is processed.

### Tag Filter (`Filter_By_Tag__c`)
When set, only tasks that have a tag matching this value (case-insensitive) are synced. All other tasks are silently skipped.

### Custom Field Filter (`Filter_Custom_Field_Name__c` + `Filter_Custom_Field_Value__c`)
When both are set, only tasks where the named custom field's display value matches the expected value are synced. Both checks must pass if both filters are configured.

---

## 8. Error Handling and Resilience

| Scenario | Behaviour |
|---|---|
| Asana API returns non-200 | Logs error with status code and body. Sync skipped for that task. |
| Task has no name | Skipped. An empty title would create an invalid User Story. |
| Field not present in Asana response | Skipped silently. Other fields still map. |
| Value not found in Value_Map | Skipped for that field only. Record still upserted with other fields. |
| Record type not found in org | Falls back to default record type or no record type assignment. |
| Tag/custom field filter not matched | Task silently skipped. No error logged, just a debug message. |
| Upsert partial failures | `Database.upsert(..., false)` allows partial success. Failures are logged per record. |
| PAT not configured | Method returns early with a debug message. Nothing is called. |
| Webhook handshake (X-Hook-Secret) | Handled automatically. Secret saved, echoed back, 200 returned. |

---

## 9. Configuration Reference

### Named Credential

| Setting | Value |
|---|---|
| Label | AsanaCopado |
| Name | AsanaCopado |
| URL | `https://app.asana.com` |
| Identity Type | Named Principal |
| Authentication Protocol | No Authentication |

The PAT is passed as a runtime `Authorization: Bearer {PAT}` header by the code, not via Named Credential auth. This keeps the Named Credential purely as a URL store and CSP whitelist entry.

### Salesforce Site

| Setting | Value |
|---|---|
| Site Label | AsanaIntegration |
| Site Name | AsanaIntegration |
| Status | Active |
| Guest User Access | AsanaWebhookEndpoint (Apex class) |

### Remote Site Setting
Salesforce automatically creates a Remote Site entry when a Named Credential is used, so no manual Remote Site setup is needed.

---

## 10. Deployment Guide

### Prerequisites
- Salesforce org with Copado installed.
- Node.js and Salesforce CLI (`sf`) installed locally.
- GitHub access to `svenkateshcopado/CopadoPartnerSuccess`.
- An Asana Personal Access Token.
- The GID of the Asana project to integrate with.

### Step 1: Clone the repository
```bash
git clone https://github.com/svenkateshcopado/CopadoPartnerSuccess.git
cd CopadoPartnerSuccess
```

### Step 2: Authenticate to your target org
```bash
sf org login web --alias my-org
```

### Step 3: Deploy the metadata
```bash
sf project deploy start --source-dir force-app --target-org my-org
```

### Step 4: Create the Named Credential
In Setup, search for Named Credentials and create one with the values in Section 9.

### Step 5: Create the Salesforce Site
In Setup, search for Sites. Create a new Site named `AsanaIntegration`. Once active, go to the Site's guest user profile and add `AsanaWebhookEndpoint` to the enabled Apex classes.

### Step 6: Configure the Custom Setting
In Setup > Custom Settings > Asana Integration Settings > Manage, create a new Org Default record and fill in:
- Asana PAT
- Asana Project GID
- (Optional) Filter By Tag
- (Optional) Filter Custom Field Name and Value

### Step 7: Update the webhook registration URL
Open `AsanaWebhookRegistration.cls` and replace `YOUR_SITE_URL` with your actual site URL (found on the Sites setup page, in the Site URL column).

Deploy the updated class:
```bash
sf project deploy start --source-dir force-app/main/default/classes/AsanaWebhookRegistration.cls --target-org my-org
```

### Step 8: Register the Asana webhook
In the Developer Console or VS Code, run:
```apex
AsanaWebhookRegistration.registerWebhook();
```

### Step 9: Update Completion Status CMDT record
In Setup > Custom Metadata Types > Asana Field Mapping > Manage Records, open the `Completion status` record and replace the placeholder GIDs in `Value_Map__c` and `Asana_Field_API_Name__c` with your actual Asana custom field GIDs.

---

## 11. Post-Deployment Checklist

- [ ] Named Credential `AsanaCopado` created and pointing to `https://app.asana.com`
- [ ] Site `AsanaIntegration` created and active
- [ ] Site guest user can access `AsanaWebhookEndpoint`
- [ ] Custom Setting org default record created with PAT and Project GID
- [ ] `AsanaWebhookRegistration.registerWebhook()` executed successfully
- [ ] `Webhook_GID__c` is populated in the Custom Setting (auto-set by registration)
- [ ] `Webhook_Secret__c` is populated (auto-set on first Asana ping)
- [ ] `Completion status` CMDT record updated with real Asana custom field GID and enum option GIDs
- [ ] Record type developer names in `Asana_Record_Type_Mapping__mdt` match your org
- [ ] Diagnostic run confirms setup: `AsanaDiagnostic.runAsync()`
- [ ] (Optional) Outbound trigger or Flow created to call `AsanaOutboundSync.updateAsanaTask()`
- [ ] (Optional) Scheduled job created: `System.schedule('Asana Daily Sync', '0 0 2 * * ?', new AsanaSyncScheduler())`

---

## 12. Troubleshooting

| Symptom | Likely Cause | Fix |
|---|---|---|
| Webhook is registered but no User Stories are created | Site guest user cannot access the endpoint | Add `AsanaWebhookEndpoint` to the Site guest user's enabled Apex classes |
| `Webhook_Secret__c` is empty | Asana never confirmed the webhook | Re-run `registerWebhook()` and check the debug log for HTTP status |
| Tasks are coming in but wrong status value | Value_Map GIDs in `Completion status` CMDT are placeholders | Update the record with real Asana enum option GIDs |
| All tasks are skipped | Tag or custom field filter is set but does not match | Check filter values in Custom Setting or clear them to sync all tasks |
| Record type is always default | Tag names in CMDT do not match actual Asana tag names | Check the exact tag name (case-insensitive but spelling must match) |
| Outbound sync does nothing | No trigger/Flow calling `updateAsanaTask()` | Create a Flow on User Story update that calls the Apex action |
| API error 401 | PAT is invalid or expired | Regenerate the Asana PAT and update the Custom Setting |
| API error 403 | PAT does not have access to the project | Check the PAT belongs to a user who is a member of the Asana project |
| Diagnostic shows 0 tasks | Project GID is wrong | Verify the GID from the Asana project URL |
| Coverage failure on deployment | Test classes are not detecting CMDT records | CMDT records deploy separately. Deploy metadata first, then run tests |
