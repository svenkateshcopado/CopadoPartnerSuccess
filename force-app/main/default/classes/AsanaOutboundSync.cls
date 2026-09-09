public class AsanaOutboundSync {

    @future(callout=true)
    public static void updateAsanaTask(String asanaTaskId, String userStoryId) {
        if (String.isBlank(asanaTaskId) || String.isBlank(userStoryId)) {
            System.debug('AsanaOutboundSync: Missing Asana Task ID or User Story ID.');
            return;
        }

        Asana_Integration_Settings__c settings = Asana_Integration_Settings__c.getOrgDefaults();

        // HIGH-01 FIX: Guard no longer checks Asana_PAT__c (removed - Named Credential handles auth).
        if (settings == null) {
            System.debug('AsanaOutboundSync: Missing integration settings.');
            return;
        }

        copado__User_Story__c us;
        try {
            us = [
                SELECT copado__User_Story_Title__c, copado__Status__c, Description__c
                FROM copado__User_Story__c
                WHERE Id = :userStoryId
                LIMIT 1
            ];
        } catch (Exception e) {
            System.debug('AsanaOutboundSync: User Story not found: ' + e.getMessage());
            return;
        }

        Map<String, Object> taskData = new Map<String, Object>();
        Map<String, Object> dataWrapper = new Map<String, Object>{ 'data' => taskData };

        List<Asana_Field_Mapping__c> mappings = [
            SELECT Asana_Field__c, Copado_Field__c
            FROM Asana_Field_Mapping__c
            WHERE Is_Active__c = true
        ];

        for (Asana_Field_Mapping__c m : mappings) {
            String copadoField = m.Copado_Field__c;
            String asanaField  = m.Asana_Field__c;
            Object val;
            if (copadoField == 'copado__User_Story_Title__c') val = us.copado__User_Story_Title__c;
            else if (copadoField == 'copado__Status__c')       val = us.copado__Status__c;
            else if (copadoField == 'Description__c')          val = us.Description__c;
            if (val != null) taskData.put(asanaField, val);
        }

        String endpoint = 'callout:AsanaCopado/api/1.0/tasks/' + asanaTaskId;

        HttpRequest req = new HttpRequest();
        req.setEndpoint(endpoint);
        req.setMethod('PUT');
        req.setHeader('Content-Type', 'application/json');
        // Named Credential injects Authorization header automatically - no manual PAT injection.
        req.setBody(JSON.serialize(dataWrapper));

        Http http = new Http();
        HttpResponse res;
        try {
            res = http.send(req);
        } catch (Exception e) {
            System.debug('AsanaOutboundSync HTTP error: ' + e.getMessage());
            return;
        }

        if (res.getStatusCode() != 200) {
            System.debug('AsanaOutboundSync: Unexpected response: ' + res.getStatusCode() + ' ' + res.getBody());
        }
    }
}