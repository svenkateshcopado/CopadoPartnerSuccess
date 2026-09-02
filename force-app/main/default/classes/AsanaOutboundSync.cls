public class AsanaOutboundSync {

    @future(callout=true)
    public static void updateAsanaTask(String asanaTaskId, String userStoryId) {
        if (String.isBlank(asanaTaskId) || String.isBlank(userStoryId)) {
            System.debug('AsanaOutboundSync: Missing Asana Task ID or User Story ID.');
            return;
        }

        Asana_Integration_Settings__c settings = Asana_Integration_Settings__c.getOrgDefaults();
        if (settings == null || String.isBlank(settings.Asana_PAT__c)) {
            System.debug('AsanaOutboundSync: Asana PAT not configured.');
            return;
        }

        List<Asana_Field_Mapping__mdt> mappings = [
            SELECT Asana_Field_API_Name__c, Copado_Field_API_Name__c, Field_Type__c
            FROM Asana_Field_Mapping__mdt
            WHERE Is_Active__c = TRUE AND Sync_Direction__c IN ('Bidirectional', 'Copado to Asana')
        ];
        if (mappings.isEmpty()) return;

        List<String> fieldAPIs = new List<String>();
        for (Asana_Field_Mapping__mdt m : mappings) {
            fieldAPIs.add(m.Copado_Field_API_Name__c);
        }

        String query = 'SELECT Id, ' + String.join(fieldAPIs, ', ') + ' FROM copado__User_Story__c WHERE Id = :userStoryId LIMIT 1';
        List<copado__User_Story__c> stories = Database.query(query);
        if (stories.isEmpty()) return;

        copado__User_Story__c us = stories[0];
        Map<String, Object> dataMap = new Map<String, Object>();

        for (Asana_Field_Mapping__mdt mapping : mappings) {
            Object fieldValue = us.get(mapping.Copado_Field_API_Name__c);
            if (fieldValue != null) {
                dataMap.put(mapping.Asana_Field_API_Name__c, fieldValue);
            }
        }

        Map<String, Object> payload = new Map<String, Object>{ 'data' => dataMap };

        // HIGH-01 FIX: Authorization header removed. Named Credential handles auth.
        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:AsanaCopado/api/1.0/tasks/' + asanaTaskId);
        req.setMethod('PUT');
        req.setHeader('Content-Type', 'application/json');
        req.setBody(JSON.serialize(payload));

        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() != 200) {
            System.debug('AsanaOutboundSync: Failed to update Asana task ' + asanaTaskId + '. Status: ' + res.getStatusCode());
        } else {
            System.debug('AsanaOutboundSync: Successfully synced User Story ' + userStoryId + ' to Asana task ' + asanaTaskId);
        }
    }
}
