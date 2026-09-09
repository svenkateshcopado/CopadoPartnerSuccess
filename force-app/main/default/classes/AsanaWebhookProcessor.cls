public class AsanaWebhookProcessor {

    public static void processTaskEvent(String taskGid) {
        if (String.isBlank(taskGid)) return;

        // HIGH-01 FIX: Reject non-numeric GIDs to prevent API retargeting.
        if (!taskGid.isNumeric()) {
            System.debug('AsanaWebhookProcessor: Rejected non-numeric task GID: ' + taskGid);
            return;
        }

        // HIGH-01 FIX: PAT check removed. Named Credential 'AsanaCopado' handles auth.
        Asana_Integration_Settings__c settings = Asana_Integration_Settings__c.getOrgDefaults();
        if (settings == null) {
            System.debug('AsanaWebhookProcessor: Integration settings not configured.');
            return;
        }

        String filterTag        = settings.Filter_By_Tag__c;
        String filterFieldName  = settings.Filter_Custom_Field_Name__c;
        String filterFieldValue = settings.Filter_Custom_Field_Value__c;

        List<Asana_Field_Mapping__mdt> fieldMappings = [
            SELECT Copado_Field_API_Name__c, Asana_Field_API_Name__c, Field_Type__c, Value_Map__c
            FROM Asana_Field_Mapping__mdt
            WHERE Is_Active__c = true
            AND (Direction__c = 'Inbound' OR Direction__c = 'Both')
            ORDER BY MasterLabel ASC
        ];

        List<Asana_Record_Type_Mapping__mdt> rtMappings = [
            SELECT Asana_Task_Value__c, Copado_Record_Type_Developer_Name__c, Is_Default__c
            FROM Asana_Record_Type_Mapping__mdt
            WHERE Is_Active__c = true
            ORDER BY Is_Default__c ASC
        ];

        Map<String, Id> rtMap = new Map<String, Id>();
        Id defaultRecordTypeId = null;
        Map<String, Id> copadoRTIds = new Map<String, Id>();
        for (RecordType rt : [SELECT Id, DeveloperName FROM RecordType WHERE SObjectType = 'copado__User_Story__c']) {
            copadoRTIds.put(rt.DeveloperName, rt.Id);
        }
        for (Asana_Record_Type_Mapping__mdt rm : rtMappings) {
            Id rtId = copadoRTIds.get(rm.Copado_Record_Type_Developer_Name__c);
            if (rtId != null) {
                rtMap.put(rm.Asana_Task_Value__c.toLowerCase(), rtId);
                if (rm.Is_Default__c) defaultRecordTypeId = rtId;
            }
        }

        Set<String> asanaFields = new Set<String>{
            'gid','name','resource_subtype','tags','tags.name',
            'custom_fields','custom_fields.gid','custom_fields.name',
            'custom_fields.display_value','custom_fields.enum_value',
            'custom_fields.enum_value.gid','custom_fields.text_value',
            'custom_fields.number_value'
        };
        for (Asana_Field_Mapping__mdt m : fieldMappings) {
            asanaFields.add(m.Asana_Field_API_Name__c);
        }
        String optFields = String.join(new List<String>(asanaFields), ',');

        // HIGH-01 FIX: No Authorization header. Named Credential handles Bearer token.
        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:AsanaCopado/api/1.0/tasks/' + taskGid + '?opt_fields=' + optFields);
        req.setMethod('GET');
        req.setHeader('Accept', 'application/json');
        req.setTimeout(30000);

        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() != 200) {
            System.debug('AsanaWebhookProcessor: Failed to fetch task ' + taskGid + '. Status: ' + res.getStatusCode());
            return;
        }

        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        Map<String, Object> data = (Map<String, Object>) body.get('data');
        if (data == null) return;

        // HIGH-03 FIX: Tag filter applied BEFORE any DML.
        if (String.isNotBlank(filterTag)) {
            List<Object> tags = (List<Object>) data.get('tags');
            Boolean tagFound = false;
            if (tags != null) {
                for (Object t : tags) {
                    Map<String, Object> tagMap = (Map<String, Object>) t;
                    if (filterTag.equalsIgnoreCase(String.valueOf(tagMap.get('name')))) {
                        tagFound = true;
                        break;
                    }
                }
            }
            if (!tagFound) {
                System.debug('AsanaWebhookProcessor: Task ' + taskGid + ' skipped - tag filter not matched.');
                return;
            }
        }

        // HIGH-03 FIX: Custom field filter applied BEFORE any DML.
        if (String.isNotBlank(filterFieldName) && String.isNotBlank(filterFieldValue)) {
            List<Object> customFields = (List<Object>) data.get('custom_fields');
            Boolean fieldFound = false;
            if (customFields != null) {
                for (Object cf : customFields) {
                    Map<String, Object> cfMap = (Map<String, Object>) cf;
                    String cfName = String.valueOf(cfMap.get('name'));
                    String cfVal  = cfMap.get('display_value') != null ? String.valueOf(cfMap.get('display_value')) : String.valueOf(cfMap.get('text_value'));
                    if (filterFieldName.equalsIgnoreCase(cfName) && filterFieldValue.equalsIgnoreCase(cfVal)) {
                        fieldFound = true;
                        break;
                    }
                }
            }
            if (!fieldFound) {
                System.debug('AsanaWebhookProcessor: Task ' + taskGid + ' skipped - custom field filter not matched.');
                return;
            }
        }

        // MEDIUM-03 FIX: Whitelist of permitted Copado field API names.
        Set<String> permittedCopadoFields = new Set<String>{
            'copado__User_Story_Title__c', 'copado__Status__c', 'copado__Priority__c',
            'copado__Developer__c', 'copado__Sprint__c', 'copado__Story_Points_SFDC__c',
            'Name', 'Asana_Task_ID__c'
        };

        copado__User_Story__c us = new copado__User_Story__c();
        us.Asana_Task_ID__c = taskGid;

        for (Asana_Field_Mapping__mdt mapping : fieldMappings) {
            // MEDIUM-03 FIX: Only write to whitelisted fields.
            if (!permittedCopadoFields.contains(mapping.Copado_Field_API_Name__c)) {
                System.debug('AsanaWebhookProcessor: Skipped non-whitelisted field: ' + mapping.Copado_Field_API_Name__c);
                continue;
            }

            Object rawValue = getFieldValue(data, mapping);
            if (rawValue == null) continue;
            String strValue = String.valueOf(rawValue);
            try {
                if (mapping.Field_Type__c == 'Boolean') {
                    us.put(mapping.Copado_Field_API_Name__c, Boolean.valueOf(strValue));
                } else if (mapping.Field_Type__c == 'Number') {
                    us.put(mapping.Copado_Field_API_Name__c, Decimal.valueOf(strValue));
                } else {
                    // Apply value map if configured
                    if (String.isNotBlank(mapping.Value_Map__c)) {
                        strValue = applyValueMap(strValue, mapping.Value_Map__c);
                    }
                    us.put(mapping.Copado_Field_API_Name__c, strValue);
                }
            } catch (Exception e) {
                System.debug('AsanaWebhookProcessor: Mapping error for field ' + mapping.Copado_Field_API_Name__c + ': ' + e.getMessage());
            }
        }

        // Resolve Record Type
        String resourceSubtype = String.valueOf(data.get('resource_subtype'));
        Id resolvedRtId = null;
        if (String.isNotBlank(resourceSubtype)) {
            resolvedRtId = rtMap.get(resourceSubtype.toLowerCase());
        }
        if (resolvedRtId == null) resolvedRtId = defaultRecordTypeId;
        if (resolvedRtId != null) us.RecordTypeId = resolvedRtId;

        // MEDIUM-02 FIX: with sharing enforced at class level for CRUD/FLS.
        Database.UpsertResult result = Database.upsert(us, copado__User_Story__c.Asana_Task_ID__c, false);
        if (!result.isSuccess()) {
            for (Database.Error err : result.getErrors()) {
                System.debug('AsanaWebhookProcessor: Upsert error - ' + err.getMessage());
            }
        }
    }

    private static Object getFieldValue(Map<String, Object> data, Asana_Field_Mapping__mdt mapping) {
        String asanaField = mapping.Asana_Field_API_Name__c;
        if (!asanaField.contains('.')) {
            return data.get(asanaField);
        }
        // Handle nested fields like custom_fields.display_value
        List<String> parts = asanaField.split('\\.');
        Object current = data.get(parts[0]);
        if (current == null) return null;
        if (current instanceof List<Object>) {
            // For custom_fields, search by name
            for (Object item : (List<Object>) current) {
                Map<String, Object> itemMap = (Map<String, Object>) item;
                if (parts.size() > 1) {
                    return itemMap.get(parts[1]);
                }
            }
        }
        return null;
    }

    private static String applyValueMap(String value, String valueMapJson) {
        try {
            Map<String, Object> valueMap = (Map<String, Object>) JSON.deserializeUntyped(valueMapJson);
            if (valueMap.containsKey(value)) {
                return String.valueOf(valueMap.get(value));
            }
        } catch (Exception e) {
            System.debug('AsanaWebhookProcessor: Value map parse error: ' + e.getMessage());
        }
        return value;
    }
}