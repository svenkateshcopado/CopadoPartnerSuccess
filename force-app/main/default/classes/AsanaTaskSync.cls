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
        if (settings == null || String.isBlank(settings.Asana_Project_GID__c)) {
            System.debug('AsanaTaskSync: Settings not configured.');
            return;
        }

        String projectGID = settings.Asana_Project_GID__c;

        // HIGH-01 FIX: Authorization header removed. Named Credential handles auth.
        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:AsanaCopado/api/1.0/projects/' + projectGID + '/tasks?opt_fields=gid,name,notes,resource_subtype,tags,custom_fields,memberships.section.name');
        req.setMethod('GET');

        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() != 200) {
            System.debug('AsanaTaskSync: Failed to fetch tasks. Status: ' + res.getStatusCode());
            return;
        }

        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        List<Object> tasks = (List<Object>) body.get('data');
        if (tasks == null || tasks.isEmpty()) return;

        List<Asana_Field_Mapping__mdt> mappings = [
            SELECT Asana_Field_API_Name__c, Copado_Field_API_Name__c, Field_Type__c
            FROM Asana_Field_Mapping__mdt
            WHERE Is_Active__c = TRUE
        ];

        List<copado__User_Story__c> toUpsert = new List<copado__User_Story__c>();

        for (Object taskObj : tasks) {
            Map<String, Object> task = (Map<String, Object>) taskObj;
            String gid = (String) task.get('gid');
            if (String.isBlank(gid) || !gid.isNumeric()) continue;

            copado__User_Story__c us = new copado__User_Story__c();
            us.Asana_Task_ID__c = gid;

            for (Asana_Field_Mapping__mdt mapping : mappings) {
                Object rawValue = task.get(mapping.Asana_Field_API_Name__c);
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
                    System.debug('AsanaTaskSync: Mapping error for field ' + mapping.Copado_Field_API_Name__c + ': ' + e.getMessage());
                }
            }
            toUpsert.add(us);
        }

        if (!toUpsert.isEmpty()) {
            upsert toUpsert Asana_Task_ID__c;
        }
    }
}
