public class AsanaWebhookProcessor {

    public static void processTaskEvent(String taskGid) {
        if (String.isBlank(taskGid)) return;

        // HIGH-01 FIX: Reject non-numeric GIDs to prevent API retargeting.
        if (!taskGid.isNumeric()) {
            System.debug('AsanaWebhookProcessor: Rejected non-numeric task GID: ' + taskGid);
            return;
        }

        Asana_Integration_Settings__c settings = Asana_Integration_Settings__c.getOrgDefaults();
        if (settings == null || String.isBlank(settings.Asana_PAT__c)) {
            System.debug('AsanaWebhookProcessor: PAT not configured.');
            return;
        }

        // Fetch the Asana task via Named Credential — no manual Bearer injection.
        // HIGH-01 FIX: Authorization header removed. Named Credential handles auth.
        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:AsanaCopado/api/1.0/tasks/' + taskGid + '?opt_fields=gid,name,notes,resource_subtype,tags,custom_fields,memberships.section.name');
        req.setMethod('GET');

        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() != 200) {
            System.debug('AsanaWebhookProcessor: Failed to fetch task ' + taskGid + '. Status: ' + res.getStatusCode());
            return;
        }

        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        Map<String, Object> data = (Map<String, Object>) body.get('data');
        if (data == null) return;

        // Field mapping and User Story upsert
        List<Asana_Field_Mapping__mdt> mappings = [
            SELECT Asana_Field_API_Name__c, Copado_Field_API_Name__c, Field_Type__c
            FROM Asana_Field_Mapping__mdt
            WHERE Is_Active__c = TRUE
        ];

        copado__User_Story__c us = new copado__User_Story__c();
        us.Asana_Task_ID__c = taskGid;

        for (Asana_Field_Mapping__mdt mapping : mappings) {
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
                System.debug('AsanaWebhookProcessor: Mapping error for field ' + mapping.Copado_Field_API_Name__c + ': ' + e.getMessage());
            }
        }

        // Resolve Record Type from tags or resource_subtype
        List<Object> tags = (List<Object>) data.get('tags');
        String resourceSubtype = (String) data.get('resource_subtype');
        String recordTypeName = resolveRecordType(tags, resourceSubtype);
        if (String.isNotBlank(recordTypeName)) {
            Schema.RecordTypeInfo rtInfo = Schema.SObjectType.copado__User_Story__c
                .getRecordTypeInfosByName().get(recordTypeName);
            if (rtInfo != null) {
                us.RecordTypeId = rtInfo.getRecordTypeId();
            }
        }

        upsert us Asana_Task_ID__c;
    }

    private static String resolveRecordType(List<Object> tags, String resourceSubtype) {
        if (tags != null) {
            for (Object tagObj : tags) {
                Map<String, Object> tag = (Map<String, Object>) tagObj;
                String tagName = (String) tag.get('name');
                List<Asana_Tag_Record_Type_Mapping__mdt> tagMappings = [
                    SELECT Copado_Record_Type_Name__c
                    FROM Asana_Tag_Record_Type_Mapping__mdt
                    WHERE Asana_Tag_Name__c = :tagName AND Is_Active__c = TRUE
                    LIMIT 1
                ];
                if (!tagMappings.isEmpty()) {
                    return tagMappings[0].Copado_Record_Type_Name__c;
                }
            }
        }
        if (String.isNotBlank(resourceSubtype)) {
            List<Asana_Tag_Record_Type_Mapping__mdt> subtypeMappings = [
                SELECT Copado_Record_Type_Name__c
                FROM Asana_Tag_Record_Type_Mapping__mdt
                WHERE Asana_Tag_Name__c = :resourceSubtype AND Is_Active__c = TRUE
                LIMIT 1
            ];
            if (!subtypeMappings.isEmpty()) {
                return subtypeMappings[0].Copado_Record_Type_Name__c;
            }
        }
        return null;
    }
}
