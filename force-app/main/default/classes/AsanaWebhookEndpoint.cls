@RestResource(urlMapping='/asana/webhook/*')
global class AsanaWebhookEndpoint {

    @HttpPost
    global static void handlePost() {
        RestRequest req   = RestContext.request;
        RestResponse res  = RestContext.response;

        String hookSecret = req.headers.get('X-Hook-Secret');
        if (String.isNotBlank(hookSecret)) {
            Asana_Integration_Settings__c settings = Asana_Integration_Settings__c.getOrgDefaults();
            if (settings != null) {
                settings.Webhook_Secret__c = hookSecret;
                update settings;
            }
            res.addHeader('X-Hook-Secret', hookSecret);
            res.statusCode = 200;
            return;
        }

        res.statusCode = 200;

        String body = req.requestBody != null ? req.requestBody.toString() : '';
        if (String.isBlank(body)) return;

        Map<String, Object> payload;
        try {
            payload = (Map<String, Object>) JSON.deserializeUntyped(body);
        } catch (Exception e) {
            System.debug('AsanaWebhookEndpoint: JSON parse error - ' + e.getMessage());
            return;
        }

        List<Object> events = (List<Object>) payload.get('events');
        if (events == null || events.isEmpty()) return;

        Set<String> taskGidsToProcess = new Set<String>();

        for (Object eventObj : events) {
            Map<String, Object> event = (Map<String, Object>) eventObj;
            String resourceType = event.containsKey('resource') ?
                String.valueOf(((Map<String, Object>) event.get('resource')).get('resource_type')) : '';
            if (resourceType != 'task') continue;

            String action = event.containsKey('action') ? String.valueOf(event.get('action')) : '';
            if (action == 'removed' || action == 'deleted') continue;

            Map<String, Object> resource = (Map<String, Object>) event.get('resource');
            String taskGid = resource != null ? String.valueOf(resource.get('gid')) : '';
            if (String.isNotBlank(taskGid)) {
                taskGidsToProcess.add(taskGid);
            }
        }

        if (Test.isRunningTest()) return;

        for (String gid : taskGidsToProcess) {
            System.enqueueJob(new AsanaWebhookQueueable(gid));
        }
    }
}