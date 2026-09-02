public class AsanaWebhookProcessor {

    // Alphanumeric-only GID validation pattern
    private static final Pattern GID_PATTERN = Pattern.compile('[a-zA-Z0-9]+');

    public static void processTaskEvent(String taskGid) {
        if (String.isBlank(taskGid)) return;

        // Validate GID format before using in callout URL
        Matcher m = GID_PATTERN.matcher(taskGid);
        if (!m.matches()) {
            System.debug('AsanaWebhookProcessor: Invalid GID format, aborting - ' + taskGid);
            return;
        }

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
        for (Asana_Field_Mapping__mdt fm : fieldMappings) {
            asanaFields.add(fm.Asana_Field_API_Name__c);
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
            System.debug('AsanaWebhookProcessor: Skipping task ' + gid + ' - empty name.');
            return;
        }

        // Build custom fields lookup map
        Map<String, String> customFieldMap = new Map<String, String>();
        List<Object> cfList = task.containsKey('custom_fields') ? (List<Object>) task.get('custom_fields') : new List<Object>();
        for (Object cfObj : cfList) {
            Map<String, Object> cf = (Map<String, Object>) cfObj;
            String cfName = cf.containsKey('name') ? String.valueOf(cf.get('name')) : '';
            String cfVal  = cf.containsKey('display_value') && cf.get('display_value') != null
                ? String.valueOf(cf.get('display_value')) : '';
            if (String.isNotBlank(cfName)) customFieldMap.put(cfName, cfVal);
        }

        // Tag filter check
        List<Object> tags = task.containsKey('tags') ? (List<Object>) task.get('tags') : new List<Object>();
        if (String.isNotBlank(filterTag)) {
            Boolean tagFound = false;
            for (Object tagObj : tags) {
                Map<String, Object> tag = (Map<String, Object>) tagObj;
                if (filterTag.equalsIgnoreCase(String.valueOf(tag.get('name')))) {
                    tagFound = true;
                    break;
                }
            }
            if (!tagFound) {
                System.debug('AsanaWebhookProcessor: Task ' + gid + ' skipped - tag filter not matched.');
                return;
            }
        }

        // Custom field filter check
        if (String.isNotBlank(filterFieldName) && String.isNotBlank(filterFieldValue)) {
            String actualVal = customFieldMap.get(filterFieldName);
            if (!filterFieldValue.equalsIgnoreCase(actualVal)) {
                System.debug('AsanaWebhookProcessor: Task ' + gid + ' skipped - custom field filter not matched.');
                return;
            }
        }

        // Determine record type
        Id resolvedRecordTypeId = defaultRecordTypeId;
        String subtype = task.containsKey('resource_subtype') ? String.valueOf(task.get('resource_subtype')).toLowerCase() : '';
        if (rtMap.containsKey(subtype)) resolvedRecordTypeId = rtMap.get(subtype);
        for (Object tagObj : tags) {
            Map<String, Object> tag = (Map<String, Object>) tagObj;
            String tagName = String.valueOf(tag.get('name')).toLowerCase();
            if (rtMap.containsKey(tagName)) {
                resolvedRecordTypeId = rtMap.get(tagName);
                break;
            }
        }

        // Build User Story record
        copado__User_Story__c us = new copado__User_Story__c();
        us.Asana_Task_ID__c = gid;
        us.copado__User_Story_Title__c = taskName;
        if (resolvedRecordTypeId != null) us.RecordTypeId = resolvedRecordTypeId;

        // Apply field mappings
        for (Asana_Field_Mapping__mdt mapping : fieldMappings) {
            String asanaFieldName = mapping.Asana_Field_API_Name__c;
            String copadoFieldName = mapping.Copado_Field_API_Name__c;
            String fieldType = mapping.Field_Type__c;
            String valueMap = mapping.Value_Map__c;

            Object rawVal = task.containsKey(asanaFieldName) ? task.get(asanaFieldName) : customFieldMap.get(asanaFieldName);
            if (rawVal == null) continue;

            String strVal = String.valueOf(rawVal);

            if (String.isNotBlank(valueMap)) {
                Map<String, Object> vm = (Map<String, Object>) JSON.deserializeUntyped(valueMap);
                if (vm.containsKey(strVal)) strVal = String.valueOf(vm.get(strVal));
            }

            try {
                if (fieldType == 'Boolean') {
                    us.put(copadoFieldName, strVal.equalsIgnoreCase('true') || strVal == '1');
                } else if (fieldType == 'Number') {
                    us.put(copadoFieldName, Decimal.valueOf(strVal));
                } else {
                    us.put(copadoFieldName, strVal);
                }
            } catch (Exception ex) {
                System.debug('AsanaWebhookProcessor: Field mapping error for ' + copadoFieldName + ' - ' + ex.getMessage());
            }
        }

        upsert us Asana_Task_ID__c;
    }
}