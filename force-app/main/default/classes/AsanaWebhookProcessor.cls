public class AsanaWebhookProcessor {

    public static void processTaskEvent(String taskGid) {
        if (String.isBlank(taskGid)) return;

        Asana_Integration_Settings__c settings = Asana_Integration_Settings__c.getOrgDefaults();
        if (settings == null || String.isBlank(settings.Asana_PAT__c)) {
            System.debug('AsanaWebhookProcessor: PAT not configured.');
            return;
        }

        String asanaPAT   = settings.Asana_PAT__c;
        String filterTag  = settings.Filter_By_Tag__c;
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

        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:AsanaCopado/api/1.0/tasks/' + taskGid + '?opt_fields=' + optFields);
        req.setMethod('GET');
        req.setHeader('Authorization', 'Bearer ' + asanaPAT);
        req.setHeader('Accept', 'application/json');
        req.setTimeout(120000);

        Http http = new Http();
        HttpResponse res = http.send(req);

        if (res.getStatusCode() != 200) {
            System.debug('AsanaWebhookProcessor: Asana API error ' + res.getStatusCode() + ' ' + res.getBody());
            return;
        }

        Map<String, Object> responseMap = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        Map<String, Object> task = (Map<String, Object>) responseMap.get('data');
        if (task == null) return;

        String gid = (String) task.get('gid');
        if (String.isBlank(gid)) return;

        String taskName = task.containsKey('name') ? String.valueOf(task.get('name')) : '';
        if (String.isBlank(taskName)) {
            System.debug('AsanaWebhookProcessor: Skipping task ' + gid + ' - empty name, not syncing to Copado.');
            return;
        }

        Map<String, Object> customFieldByGid = new Map<String, Object>();
        Object cfListObj = task.get('custom_fields');
        if (cfListObj instanceof List<Object>) {
            for (Object cfItem : (List<Object>) cfListObj) {
                Map<String, Object> cf = (Map<String, Object>) cfItem;
                if (cf.containsKey('gid')) {
                    customFieldByGid.put(String.valueOf(cf.get('gid')), cf);
                }
            }
        }

        List<String> tagNames = new List<String>();
        Object tagsObj = task.get('tags');
        if (tagsObj instanceof List<Object>) {
            for (Object tagObj : (List<Object>) tagsObj) {
                Map<String, Object> tagMap = (Map<String, Object>) tagObj;
                if (tagMap.containsKey('name')) {
                    tagNames.add(String.valueOf(tagMap.get('name')).toLowerCase());
                }
            }
        }

        if (String.isNotBlank(filterTag)) {
            Boolean hasTag = false;
            for (String t : tagNames) {
                if (t.equalsIgnoreCase(filterTag.trim())) { hasTag = true; break; }
            }
            if (!hasTag) {
                System.debug('AsanaWebhookProcessor: Skipping task ' + gid + ' - missing tag: ' + filterTag);
                return;
            }
        }

        if (String.isNotBlank(filterFieldName) && String.isNotBlank(filterFieldValue)) {
            Boolean fieldMatches = false;
            Object cfObj = task.get('custom_fields');
            if (cfObj instanceof List<Object>) {
                for (Object cfItem : (List<Object>) cfObj) {
                    Map<String, Object> cf = (Map<String, Object>) cfItem;
                    String cfName = cf.containsKey('name') ? String.valueOf(cf.get('name')) : '';
                    String cfVal  = cf.containsKey('display_value') && cf.get('display_value') != null
                                    ? String.valueOf(cf.get('display_value')) : '';
                    if (cfName.equalsIgnoreCase(filterFieldName.trim()) && cfVal.equalsIgnoreCase(filterFieldValue.trim())) {
                        fieldMatches = true; break;
                    }
                }
            }
            if (!fieldMatches) {
                System.debug('AsanaWebhookProcessor: Skipping task ' + gid + ' - custom field filter not matched.');
                return;
            }
        }

        Id resolvedRecordTypeId = defaultRecordTypeId;
        for (String tagName : tagNames) {
            if (rtMap.containsKey(tagName)) { resolvedRecordTypeId = rtMap.get(tagName); break; }
        }
        if (resolvedRecordTypeId == defaultRecordTypeId) {
            String subtype = task.containsKey('resource_subtype') ? String.valueOf(task.get('resource_subtype')).toLowerCase() : '';
            if (String.isNotBlank(subtype) && rtMap.containsKey(subtype)) {
                resolvedRecordTypeId = rtMap.get(subtype);
            }
        }

        copado__User_Story__c us = new copado__User_Story__c();
        us.put('Asana_Task_Id__c', gid);
        if (resolvedRecordTypeId != null) us.RecordTypeId = resolvedRecordTypeId;

        Set<String> mappedCopadoFields = new Set<String>();

        for (Asana_Field_Mapping__mdt m : fieldMappings) {
            if (mappedCopadoFields.contains(m.Copado_Field_API_Name__c)) continue;

            Object rawValue;
            Boolean isCustomFieldGid = m.Asana_Field_API_Name__c.isNumeric();

            if (isCustomFieldGid && customFieldByGid.containsKey(m.Asana_Field_API_Name__c)) {
                Map<String, Object> cf = (Map<String, Object>) customFieldByGid.get(m.Asana_Field_API_Name__c);
                if (cf.containsKey('enum_value') && cf.get('enum_value') != null) {
                    Map<String, Object> enumVal = (Map<String, Object>) cf.get('enum_value');
                    rawValue = enumVal.containsKey('gid') ? enumVal.get('gid') : null;
                } else if (cf.containsKey('text_value') && cf.get('text_value') != null) {
                    rawValue = cf.get('text_value');
                } else if (cf.containsKey('number_value') && cf.get('number_value') != null) {
                    rawValue = cf.get('number_value');
                } else if (cf.containsKey('display_value') && cf.get('display_value') != null) {
                    rawValue = cf.get('display_value');
                }
            } else {
                rawValue = task.get(m.Asana_Field_API_Name__c);
            }

            if (rawValue == null) continue;

            if (String.isNotBlank(m.Value_Map__c)) {
                Map<String, Object> valueMap = (Map<String, Object>) JSON.deserializeUntyped(m.Value_Map__c);
                String rawStr = String.valueOf(rawValue);
                if (valueMap.containsKey(rawStr)) {
                    us.put(m.Copado_Field_API_Name__c, String.valueOf(valueMap.get(rawStr)));
                    mappedCopadoFields.add(m.Copado_Field_API_Name__c);
                }
            } else {
                if (m.Field_Type__c == 'Boolean') {
                    us.put(m.Copado_Field_API_Name__c, Boolean.valueOf(String.valueOf(rawValue)));
                } else if (m.Field_Type__c == 'Number') {
                    us.put(m.Copado_Field_API_Name__c, Decimal.valueOf(String.valueOf(rawValue)));
                } else {
                    us.put(m.Copado_Field_API_Name__c, String.valueOf(rawValue));
                }
                mappedCopadoFields.add(m.Copado_Field_API_Name__c);
            }
        }

        Schema.SObjectField externalIdField = Schema.SObjectType.copado__User_Story__c.fields.getMap().get('Asana_Task_Id__c');
        Database.upsert(new List<copado__User_Story__c>{us}, externalIdField, false);
        System.debug('AsanaWebhookProcessor: Upserted User Story for task GID: ' + gid);
    }
}