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

    public static void doSync() {
        Asana_Integration_Settings__c settings = Asana_Integration_Settings__c.getOrgDefaults();

        // HIGH-01 FIX: No longer reads Asana_PAT__c. Named Credential handles auth.
        if (settings == null || String.isBlank(settings.Asana_Project_GID__c)) {
            System.debug('AsanaTaskSync: Missing project GID in settings.');
            return;
        }

        String projectGid = settings.Asana_Project_GID__c;
        String endpoint = 'callout:AsanaCopado/api/1.0/projects/' + projectGid + '/tasks?opt_fields=gid,name,notes,due_on,assignee,tags,custom_fields,resource_subtype,memberships.section.name';

        HttpRequest req = new HttpRequest();
        req.setEndpoint(endpoint);
        req.setMethod('GET');
        // Named Credential injects Authorization header automatically - no manual PAT injection.

        Http http = new Http();
        HttpResponse res;
        try {
            res = http.send(req);
        } catch (Exception e) {
            System.debug('AsanaTaskSync HTTP error: ' + e.getMessage());
            return;
        }

        if (res.getStatusCode() != 200) {
            System.debug('AsanaTaskSync: Non-200 response: ' + res.getStatusCode());
            return;
        }

        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        List<Object> tasks = (List<Object>) parsed.get('data');
        if (tasks == null || tasks.isEmpty()) return;

        List<Asana_Field_Mapping__c> mappings = [
            SELECT Asana_Field__c, Copado_Field__c
            FROM Asana_Field_Mapping__c
            WHERE Is_Active__c = true
        ];

        List<copado__User_Story__c> toUpsert = new List<copado__User_Story__c>();
        List<String> seenGids = new List<String>();

        for (Object taskObj : tasks) {
            Map<String, Object> task = (Map<String, Object>) taskObj;
            String subtype = (String) task.get('resource_subtype');
            if (subtype == 'section') continue;

            String gid = (String) task.get('gid');
            if (String.isBlank(gid)) continue;
            seenGids.add(gid);

            copado__User_Story__c us = new copado__User_Story__c(
                Asana_Task_GID__c = gid
            );

            for (Asana_Field_Mapping__c m : mappings) {
                String asanaField = m.Asana_Field__c;
                String copadoField = m.Copado_Field__c;
                Object rawVal = task.get(asanaField);
                if (rawVal == null) continue;
                String strVal = String.valueOf(rawVal);
                if (copadoField == 'copado__User_Story_Title__c') {
                    us.copado__User_Story_Title__c = strVal;
                } else if (copadoField == 'copado__Status__c') {
                    us.copado__Status__c = strVal;
                } else if (copadoField == 'Description__c') {
                    us.Description__c = strVal;
                }
            }

            // Tags
            List<Object> tags = (List<Object>) task.get('tags');
            if (tags != null && !tags.isEmpty()) {
                List<String> tagNames = new List<String>();
                for (Object t : tags) {
                    Map<String, Object> tagMap = (Map<String, Object>) t;
                    tagNames.add((String) tagMap.get('name'));
                }
                us.Asana_Tags__c = String.join(tagNames, ',');
            }

            // Custom fields
            List<Object> customFields = (List<Object>) task.get('custom_fields');
            if (customFields != null) {
                for (Object cf : customFields) {
                    Map<String, Object> cfMap = (Map<String, Object>) cf;
                    String cfName = (String) cfMap.get('name');
                    Object cfVal = cfMap.get('display_value');
                    if (cfName == 'Priority' && cfVal != null) {
                        us.Asana_Priority__c = String.valueOf(cfVal);
                    }
                }
            }

            // Section
            List<Object> memberships = (List<Object>) task.get('memberships');
            if (memberships != null && !memberships.isEmpty()) {
                Map<String, Object> mem = (Map<String, Object>) memberships[0];
                Map<String, Object> section = (Map<String, Object>) mem.get('section');
                if (section != null) {
                    us.Asana_Section__c = (String) section.get('name');
                }
            }

            toUpsert.add(us);
        }

        if (!toUpsert.isEmpty()) {
            upsert toUpsert Asana_Task_GID__c;
        }
    }
}