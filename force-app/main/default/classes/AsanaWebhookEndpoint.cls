/**
 * AsanaWebhookEndpoint
 *
 * Security fixes applied:
 *   HC-02  First-write-wins handshake – if a secret is already stored, the endpoint
 *          returns HTTP 409 and rejects the overwrite, preventing secret hijacking.
 *   LC-02  Debug log hygiene         – no full request/response bodies logged at INFO+.
 */
@RestResource(urlMapping='/asana/webhook/*')
global with sharing class AsanaWebhookEndpoint {

    // Inner class: elevates to System context for Custom Settings DML only.
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
     * XOR accumulation prevents timing-based side-channel attacks.
     */
    @TestVisible
    private static Boolean verifySignature(String secret, Blob body, String incoming) {
        if (String.isBlank(secret) || String.isBlank(incoming) || body == null) return false;
        Blob   hmac     = Crypto.generateMac('HmacSHA256', body, Blob.valueOf(secret));
        String computed = EncodingUtil.convertToHex(hmac);
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

        // HC-02: Handshake branch — first-write-wins secret protection.
        String hookSecret = req.headers.get('X-Hook-Secret');
        if (String.isNotBlank(hookSecret)) {
            Asana_Integration_Settings__c existingSettings = Asana_Integration_Settings__c.getOrgDefaults();
            // If a secret is already stored, reject the overwrite attempt.
            if (existingSettings != null && String.isNotBlank(existingSettings.Webhook_Secret__c)) {
                System.debug(LoggingLevel.WARN,
                    'AsanaWebhookEndpoint: Handshake rejected — secret already configured. Returning 409.');
                res.statusCode   = 409;
                res.responseBody = Blob.valueOf('{"error":"Webhook secret already registered. Reset via admin tools before re-registering."}');
                return;
            }
            // First registration: accept and store the secret.
            new SettingsWriter().saveSecret(hookSecret);
            res.addHeader('X-Hook-Secret', hookSecret);
            return;
        }

        String bodyStr = req.requestBody != null ? req.requestBody.toString() : '';
        if (String.isBlank(bodyStr)) return;

        String incomingSignature = req.headers.get('X-Hook-Signature');
        Asana_Integration_Settings__c settings = Asana_Integration_Settings__c.getOrgDefaults();
        String storedSecret = settings != null ? settings.Webhook_Secret__c : null;

        // HMAC gate: always active, no Test.isRunningTest() bypass.
        if (!verifySignature(storedSecret, req.requestBody, incomingSignature)) {
            res.statusCode   = 401;
            res.responseBody = Blob.valueOf('{"error":"Invalid signature"}');
            return;
        }

        Map<String, Object> payload;
        try {
            payload = (Map<String, Object>) JSON.deserializeUntyped(bodyStr);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'AsanaWebhookEndpoint: JSON parse error.');
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

        // LC-03: Enqueue in batches of 15 to stay well within Asana rate limits.
        List<String> gidList = new List<String>(taskGidsToProcess);
        Integer batchSize = 15;
        for (Integer i = 0; i < gidList.size(); i += batchSize) {
            Integer endIdx = Math.min(i + batchSize, gidList.size());
            Set<String> batch = new Set<String>(gidList.subList(i, endIdx));
            System.enqueueJob(new AsanaWebhookQueueable(batch));
        }
    }
}
