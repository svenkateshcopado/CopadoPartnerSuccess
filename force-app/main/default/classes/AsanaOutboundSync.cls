public class AsanaOutboundSync {

    @future(callout=true)
    public static void updateAsanaTask(String asanaTaskId, String userStoryId) {
        if (String.isBlank(asanaTaskId) || String.isBlank(userStoryId)) {
            System.debug('AsanaOutboundSync: Missing Asana Task ID or User Story ID.');
            return;
        }

        Asana_Integration_Settings__c settings = Asana_Integration_Settings__c.getOrgDefaults();
        if (settings == null || String.isBlank(settings.Asana_PAT__c)) {
            System.debug('AsanaOutboundSync: Asana PAT not configured in Asana Integration Settings.');
            return;
        }

        String asanaPAT = settings.Asana_PAT__c;

        List<Asana_Field_Mapping__mdt> mappings = [
            SELECT Copado_Field_API_Name__c, Asana_Field_API_Name__c, Field_Type__c, Value_Map__c
            FROM Asana_Field_Mapping__mdt
            WHERE Is_Active__c = true
            AND (Direction__c = 'Outbound' OR Direction__c = 'Both')
            ORDER BY MasterLabel ASC
        ];

        if (mappings.isEmpty()) {
            System.debug('AsanaOutboundSync: No active outbound mappings found.');
            return;
        }

        Set<String> fieldApiNames = new Set<String>{'Id'};
        for (Asana_Field_Mapping__mdt m : mappings) {
            fieldApiNames.add(m.Copado_Field_API_Name__c);
        }

        String soql = 'SELECT ' + String.join(new List<String>(fieldApiNames), ',') +
                      ' FROM copado__User_Story__c WHERE Id = :userStoryId LIMIT 1';
        List<copado__User_Story__c> stories = Database.query(soql);

        if (stories.isEmpty()) {
            System.debug('AsanaOutboundSync: User Story not found.');
            return;
        }

        copado__User_Story__c us = stories[0];

        Map<String, Object> dataMap = new Map<String, Object>();
        Map<String, Object> customFieldsMap = new Map<String, Object>();

        for (Asana_Field_Mapping__mdt m : mappings) {
            Object rawValue = us.get(m.Copado_Field_API_Name__c);
            if (rawValue == null) continue;

            Boolean isCustomField = m.Asana_Field_API_Name__c.isNumeric();
            Object finalValue;

            if (String.isNotBlank(m.Value_Map__c)) {
                Map<String, Object> valueMap = (Map<String, Object>) JSON.deserializeUntyped(m.Value_Map__c);
                Map<String, String> reverseMap = new Map<String, String>();
                for (String key : valueMap.keySet()) {
                    reverseMap.put(String.valueOf(valueMap.get(key)), key);
                }
                String rawStr = String.valueOf(rawValue);
                String mapped = reverseMap.get(rawStr);
                if (mapped == null) {
                    System.debug('AsanaOutboundSync: No reverse mapping found for value "' + rawStr + '" on field ' + m.Asana_Field_API_Name__c);
                    continue;
                }
                finalValue = mapped;
            } else {
                if (m.Field_Type__c == 'Boolean') {
                    finalValue = Boolean.valueOf(String.valueOf(rawValue));
                } else if (m.Field_Type__c == 'Number') {
                    finalValue = Decimal.valueOf(String.valueOf(rawValue));
                } else {
                    finalValue = String.valueOf(rawValue);
                }
            }

            if (isCustomField) {
                customFieldsMap.put(m.Asana_Field_API_Name__c, finalValue);
            } else {
                dataMap.put(m.Asana_Field_API_Name__c, finalValue);
            }
        }

        if (!customFieldsMap.isEmpty()) {
            dataMap.put('custom_fields', customFieldsMap);
        }

        if (dataMap.isEmpty()) {
            System.debug('AsanaOutboundSync: No data to send to Asana.');
            return;
        }

        Map<String, Object> body = new Map<String, Object>();
        body.put('data', dataMap);

        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:AsanaCopado/api/1.0/tasks/' + asanaTaskId);
        req.setMethod('PUT');
        req.setHeader('Authorization', 'Bearer ' + asanaPAT);
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('Accept', 'application/json');
        req.setBody(JSON.serialize(body));
        req.setTimeout(120000);

        Http http = new Http();
        HttpResponse res = http.send(req);

        if (res.getStatusCode() == 200) {
            System.debug('AsanaOutboundSync: Successfully updated Asana task ' + asanaTaskId);
        } else {
            System.debug('AsanaOutboundSync: Failed - ' + res.getStatusCode() + ' ' + res.getBody());
        }
    }
}