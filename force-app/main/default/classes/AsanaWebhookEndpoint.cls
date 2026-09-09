@RestResource(urlMapping='/asana/webhook/*')
global with sharing class AsanaWebhookEndpoint {

    // --- Inner class: elevates to System context for Custom Settings DML -------
    private without sharing class SettingsWriter {
        public void saveSecret(String secret) {
            Asana_Integration_Settings__c settings = Asana_Integration_Settings__c.getOrgDefaults();
            if (settings == null) {
                settings = new Asana_Integration_Settings__c();
                settings.SetupOwnerId = UserInfo.getOrganizationId();
            }
            settings.Webhook_Secret__c = secret;
            upsert settings;
        }
    }

    /**
     * Constant-time HMAC-SHA256 comparison.
     * Uses XOR accumulation across all character pairs so that execution time
     * does not depend on the position of the first differing byte, preventing
     * timing-based side-channel attacks (C-2 fix).
     */
    @TestVisible
    private static Boolean verifySignature(String secret, Blob body, String incoming) {
        if (String.isBlank(secret) || String.isBlank(incoming) || body == null) return false;
        Blob   hmac     = Crypto.generateMac('HmacSHA256', body, Blob.valueOf(secret));
        String computed = EncodingUtil.convertToHex(hmac);
        // Length mismatch check (also constant-time safe: no character comparison done)
        if (computed.length() != incoming.length()) return false;
        Integer diff = 0;
        for (Integer i = 0; i < computed.length(); i++) {
            diff |= computed.charAt(i) ^ incoming.charAt(i);
        }
        return diff == 0;
    }

    @HttpPost
    global static void handlePost() {
        RestRequest  req = RestContext.request;
        RestResponse res = RestContext.response;
        res.statusCode = 200;

        // Handshake: Asana sends X-Hook-Secret on first registration
        String hookSecret = req.headers.get('X-Hook-Secret');
        if (String.isNotBlank(hookSecret)) {
            new SettingsWriter().saveSecret(hookSecret);
            res.addHeader('X-Hook-Secret', hookSecret);
            return;
        }

        String bodyStr = req.requestBody != null ? req.requestBody.toString() : '';
        if (String.isBlank(bodyStr)) return;

        String incomingSignature = req.headers.get('X-Hook-Signature');
        Asana_Integration_Settings__c settings = Asana_Integration_Settings__c.getOrgDefaults();
        String storedSecret = settings != null ? settings.Webhook_Secret__c : null;

        // HMAC gate: always active, no Test.isRunningTest() bypass (C-1 fix)
        if (!verifySignature(storedSecret, req.requestBody, incomingSignature)) {
            res.statusCode   = 401;
            res.responseBody = Blob.valueOf('{"error":"Invalid signature"}');
            return;
        }

        Map<String, Object> payload;
        try {
            payload = (Map<String, Object>) JSON.deserializeUntyped(bodyStr);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'AsanaWebhookEndpoint: JSON parse error - ' + e.getMessage());
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

        if (taskGidsToProcess.isEmpty()) return;

        System.enqueueJob(new AsanaWebhookQueueable(taskGidsToProcess));
    }
}