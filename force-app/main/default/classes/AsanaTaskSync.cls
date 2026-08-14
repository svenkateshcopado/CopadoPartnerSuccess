public class AsanaTaskSync {

    @InvocableMethod(label='Sync Asana Tasks to Copado User Stories' description='Calls Asana API and upserts User Stories based on active field mappings')
    public static void syncTasks(List<String> inputs) {
        if (System.isFuture() || System.isBatch()) {
            doSync();
        } else {
            syncAsync();
        }
    }

    @future(callout=true)
    private static void syncAsync() {
        doSync();
    }

    private static void doSync() {
        Asana_Integration_Settings__c settings = Asana_Integration_Settings__c.getOrgDefaults();
        if (settings == null || String.isBlank(settings.Asana_PAT__c) || String.isBlank(settings.Asana_Project_GID__c)) {
            System.debug('AsanaTaskSync: Asana Integration Settings not configured. Please set PAT and Project GID.');
            return;
        }

        String asanaPAT       = settings.Asana_PAT__c;
        String projectGID     = settings.Asana_Project_GID__c;
        String filterTag      = settings.Filter_By_Tag__c;
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

        Set<String> asanaFields = new Set<String>{'gid', 'name', 'resource_subtype', 'tags', 'tags.name', 'custom_fields', 'custom_fields.name', 'custom_fields.display_value'};
        for (Asana_Field_Mapping__mdt m : fieldMappings) {
            asanaFields.add(m.Asana_Field_API_Name__c);
        }
        String optFields = String.join(new List<String>(asanaFields), ',');

        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:AsanaCopado/api/1.0/projects/' + projectGID + '/tasks?opt_fields=' + optFields);
        req.setMethod('GET');
        req.setHeader('Authorization', 'Bearer ' + asanaPAT);
        req.setHeader('Accept', 'application/json');
        req.setTimeout(120000);

        Http http = new Http();
        HttpResponse res = http.send(req);

        if (res.getStatusCode() != 200) {
            System.debug('AsanaTaskSync: Asana API error: ' + res.getStatusCode() + ' ' + res.getBody());
            return;
        }

        Map<String, Object> responseMap = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        List<Object> tasks = (List<Object>) responseMap.get('data');
        if (tasks == null || tasks.isEmpty()) return;

        List<copado__User_Story__c> storiesToUpsert = new List<copado__User_Story__c>();

        for (Object taskObj : tasks) {
            Map<String, Object> task = (Map<String, Object>) taskObj;
            String gid = (String) task.get('gid');
            if (String.isBlank(gid)) continue;

            List<String> tagNames = new List<String>();
            Object tagsObj = task.get('tags');
            if (tagsObj instanceof List<Object>) {
                for (Object tagObj : (List<Object>) tagsObj) {
                    Map<String, Object> tagMap = (Map<String, Object>) tagObj;
                    if (tagMap.containsKey('name')) tagNames.add(String.valueOf(tagMap.get('name')).toLowerCase());
                }
            }

            if (String.isNotBlank(filterTag)) {
                Boolean hasTag = false;
                for (String t : tagNames) { if (t.equalsIgnoreCase(filterTag.trim())) { hasTag = true; break; } }
                if (!hasTag) continue;
            }

            if (String.isNotBlank(filterFieldName) && String.isNotBlank(filterFieldValue)) {
                Boolean fieldMatches = false;
                Object cfObj = task.get('custom_fields');
                if (cfObj instanceof List<Object>) {
                    for (Object cfItem : (List<Object>) cfObj) {
                        Map<String, Object> cf = (Map<String, Object>) cfItem;
                        String cfName = cf.containsKey('name') ? String.valueOf(cf.get('name')) : '';
                        String cfVal  = cf.containsKey('display_value') && cf.get('display_value') != null ? String.valueOf(cf.get('display_value')) : '';
                        if (cfName.equalsIgnoreCase(filterFieldName.trim()) && cfVal.equalsIgnoreCase(filterFieldValue.trim())) { fieldMatches = true; break; }
                    }
                }
                if (!fieldMatches) continue;
            }

            Id resolvedRecordTypeId = defaultRecordTypeId;
            for (String tagName : tagNames) { if (rtMap.containsKey(tagName)) { resolvedRecordTypeId = rtMap.get(tagName); break; } }
            if (resolvedRecordTypeId == defaultRecordTypeId) {
                String subtype = task.containsKey('resource_subtype') ? String.valueOf(task.get('resource_subtype')).toLowerCase() : '';
                if (String.isNotBlank(subtype) && rtMap.containsKey(subtype)) resolvedRecordTypeId = rtMap.get(subtype);
            }

            copado__User_Story__c us = new copado__User_Story__c();
            us.put('Asana_Task_Id__c', gid);
            if (resolvedRecordTypeId != null) us.RecordTypeId = resolvedRecordTypeId;

            for (Asana_Field_Mapping__mdt m : fieldMappings) {
                Object rawValue = task.get(m.Asana_Field_API_Name__c);
                if (rawValue == null) continue;
                if (String.isNotBlank(m.Value_Map__c)) {
                    Map<String, Object> valueMap = (Map<String, Object>) JSON.deserializeUntyped(m.Value_Map__c);
                    String rawStr = String.valueOf(rawValue);
                    if (valueMap.containsKey(rawStr)) us.put(m.Copado_Field_API_Name__c, String.valueOf(valueMap.get(rawStr)));
                } else {
                    if (m.Field_Type__c == 'Boolean') us.put(m.Copado_Field_API_Name__c, Boolean.valueOf(String.valueOf(rawValue)));
                    else if (m.Field_Type__c == 'Number') us.put(m.Copado_Field_API_Name__c, Decimal.valueOf(String.valueOf(rawValue)));
                    else us.put(m.Copado_Field_API_Name__c, String.valueOf(rawValue));
                }
            }
            storiesToUpsert.add(us);
        }

        if (!storiesToUpsert.isEmpty()) {
            Schema.SObjectField externalIdField = Schema.SObjectType.copado__User_Story__c.fields.getMap().get('Asana_Task_Id__c');
            Database.upsert(storiesToUpsert, externalIdField, false);
            System.debug('AsanaTaskSync: Upserted ' + storiesToUpsert.size() + ' User Stories from Asana.');
        }
    }
}