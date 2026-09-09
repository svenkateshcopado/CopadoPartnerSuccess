/**
 * AsanaWebhookProcessor
 *
 * Security fixes applied:
 *   HC-01  SOQL-in-loop eliminated  – tag mappings pre-queried into a Map before iteration.
 *   HC-03  Stale PAT guard removed   – guard now checks Asana_Project_GID__c (consistent with rest of codebase).
 *   MC-02  Explicit sharing declared  – class declared 'with sharing'; upsert delegated to inner UpsertWriter (without sharing).
 *   MC-03  Field-mapping allowlist    – every dynamic put() validated against ALLOWED_TARGET_FIELDS; blocked fields are logged and skipped.
 *   LC-02  Debug log hygiene         – response bodies / GIDs only logged at DEBUG level; no sensitive data at INFO+.
 */
public with sharing class AsanaWebhookProcessor {

    // MC-03: Allowlist of Copado User Story fields that inbound mapping is permitted to write.
    // Add new fields here after a deliberate review; never expand automatically from metadata.
    @TestVisible
    private static final Set<String> ALLOWED_TARGET_FIELDS = new Set<String>{
        'copado__User_Story_Title__c',
        'copado__Status__c',
        'copado__Priority__c',
        'copado__Story_Points_SFDC__c',
        'copado__Story_Points_Other__c',
        'Description__c',
        'Asana_Task_ID__c',
        'Asana_Section__c',
        'Asana_Due_Date__c',
        'Asana_Assignee__c'
    };

    // MC-02: Inner class elevated to without sharing solely for the upsert DML.
    private without sharing class UpsertWriter {
        public void doUpsert(copado__User_Story__c us) {
            upsert us Asana_Task_ID__c;
        }
    }

    public static void processTaskEvent(String taskGid) {
        if (String.isBlank(taskGid)) return;

        // Reject non-numeric GIDs to prevent API retargeting.
        if (!taskGid.isNumeric()) {
            System.debug(LoggingLevel.WARN, 'AsanaWebhookProcessor: Rejected non-numeric task GID.');
            return;
        }

        // HC-03: Guard on Project GID, not PAT. Named Credential handles auth.
        Asana_Integration_Settings__c settings = Asana_Integration_Settings__c.getOrgDefaults();
        if (settings == null || String.isBlank(settings.Asana_Project_GID__c)) {
            System.debug(LoggingLevel.ERROR, 'AsanaWebhookProcessor: Asana_Project_GID__c not configured.');
            return;
        }

        // Fetch full task details via Named Credential (no manual Bearer header).
        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:AsanaCopado/api/1.0/tasks/' + taskGid +
            '?opt_fields=gid,name,notes,resource_subtype,tags,custom_fields,memberships.section.name');
        req.setMethod('GET');
        req.setTimeout(30000); // LC-01: 30-second timeout

        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() != 200) {
            // LC-02: Do not log full response body; log only status code.
            System.debug(LoggingLevel.ERROR, 'AsanaWebhookProcessor: Task fetch failed. HTTP ' + res.getStatusCode());
            return;
        }

        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        Map<String, Object> data = (Map<String, Object>) body.get('data');
        if (data == null) return;

        // HC-01: Pre-query ALL tag-to-record-type mappings into a Map before any loop.
        Map<String, String> tagToRecordType = new Map<String, String>();
        for (Asana_Tag_Record_Type_Mapping__mdt m : [
            SELECT Asana_Tag_Name__c, Copado_Record_Type_Name__c
            FROM Asana_Tag_Record_Type_Mapping__mdt
            WHERE Is_Active__c = TRUE
        ]) {
            tagToRecordType.put(m.Asana_Tag_Name__c, m.Copado_Record_Type_Name__c);
        }

        // Field mapping
        List<Asana_Field_Mapping__mdt> mappings = [
            SELECT Asana_Field_API_Name__c, Copado_Field_API_Name__c, Field_Type__c
            FROM Asana_Field_Mapping__mdt
            WHERE Is_Active__c = TRUE
        ];

        copado__User_Story__c us = new copado__User_Story__c();
        us.Asana_Task_ID__c = taskGid;

        for (Asana_Field_Mapping__mdt mapping : mappings) {
            // MC-03: Reject any mapping that targets a field outside the allowlist.
            if (!ALLOWED_TARGET_FIELDS.contains(mapping.Copado_Field_API_Name__c)) {
                System.debug(LoggingLevel.WARN,
                    'AsanaWebhookProcessor: Blocked disallowed target field: ' + mapping.Copado_Field_API_Name__c);
                continue;
            }

            Object rawValue = data.get(mapping.Asana_Field_API_Name__c);
            if (rawValue == null) continue;
            String strValue = String.valueOf(rawValue);
            try {
                if (mapping.Field_Type__c == 'Boolean') {
                    us.put(mapping.Copado_Field_API_Name__c, Boolean.valueOf(strValue));
                } else if (mapping.Field_Type__c == 'Number') {
                    us.put(mapping.Copado_Field_API_Name__c, Decimal.valueOf(strValue));
                } else {
                    us.put(mapping.Copado_Field_API_Name__c, strValue);
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN,
                    'AsanaWebhookProcessor: Mapping error for field ' + mapping.Copado_Field_API_Name__c);
            }
        }

        // HC-01: resolveRecordType now uses the pre-queried Map — zero SOQL inside loop.
        List<Object> tags = (List<Object>) data.get('tags');
        String resourceSubtype = (String) data.get('resource_subtype');
        String recordTypeName = resolveRecordType(tags, resourceSubtype, tagToRecordType);
        if (String.isNotBlank(recordTypeName)) {
            Schema.RecordTypeInfo rtInfo = Schema.SObjectType.copado__User_Story__c
                .getRecordTypeInfosByName().get(recordTypeName);
            if (rtInfo != null) {
                us.RecordTypeId = rtInfo.getRecordTypeId();
            }
        }

        // MC-02: Delegate DML to without sharing inner class.
        new UpsertWriter().doUpsert(us);
    }

    /**
     * HC-01 fix: accepts a pre-populated Map instead of issuing SOQL per iteration.
     * No database calls happen inside this method.
     */
    private static String resolveRecordType(
        List<Object> tags,
        String resourceSubtype,
        Map<String, String> tagToRecordType
    ) {
        if (tags != null) {
            for (Object tagObj : tags) {
                Map<String, Object> tag = (Map<String, Object>) tagObj;
                String tagName = (String) tag.get('name');
                if (tagToRecordType.containsKey(tagName)) {
                    return tagToRecordType.get(tagName);
                }
            }
        }
        if (String.isNotBlank(resourceSubtype) && tagToRecordType.containsKey(resourceSubtype)) {
            return tagToRecordType.get(resourceSubtype);
        }
        return null;
    }
}
