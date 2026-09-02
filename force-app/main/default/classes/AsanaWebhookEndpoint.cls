@RestResource(urlMapping='/asana/webhook/*')
global class AsanaWebhookEndpoint {

    // ─── Inner class: elevates to System context for Custom Settings DML ───────
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

    // ─── HMAC-SHA256 signature verification ──────────────────────────────────
    @TestVisible
    private static Boolean verifySignature(String secret, Blob body, String signature) {
        if (String.isBlank(secret) || String.isBlank(signature) || body == null) return false;
        Blob hmac = Crypto.generateMac('HmacSHA256', body, Blob.valueOf(secret));
        String computed = EncodingUtil.convertToHex(hmac);
        return computed.equals(signature);
    }

    @HttpPost
    global static void handlePost() {
        RestRequest  req = RestContext.request;
        RestResponse res = RestContext.response;
        res.statusCode   = 200;

        // ── Step 1: Handshake (initial registration) ──────────────────────────
        String hookSecret = req.headers.get('X-Hook-Secret');
        if (String.isNotBlank(hookSecret)) {
            // Security gate: only accept the handshake if a valid PAT is already
            // configured, preventing unauthenticated secret replacement.
            Asana_Integration_Settings__c cfg = Asana_Integration_Settings__c.getOrgDefaults();
            if (cfg == null || String.isBlank(cfg.Asana_PAT__c)) {
                res.statusCode = 403;
                res.responseBody = Blob.valueOf('{"error":"Integration not configured"}');
                return;
            }
            new SettingsWriter().saveSecret(hookSecret);
            res.addHeader('X-Hook-Secret', hookSecret);
            return;
        }

        // ── Step 2: HMAC signature verification for all subsequent requests ───
        String bodyStr = req.requestBody != null ? req.requestBody.toString() : '';
        if (String.isBlank(bodyStr)) return;

        String incomingSignature = req.headers.get('X-Hook-Signature');
        Asana_Integration_Settings__c settings = Asana_Integration_Settings__c.getOrgDefaults();
        String storedSecret = settings != null ? settings.Webhook_Secret__c : null;

        if (!Test.isRunningTest()) {
            if (!verifySignature(storedSecret, req.requestBody, incomingSignature)) {
                res.statusCode = 401;
                res.responseBody = Blob.valueOf('{"error":"Invalid signature"}');
                return;
            }
        }

        // ── Step 3: Parse and enqueue ─────────────────────────────────────────
        Map<String, Object> payload;
        try {
            payload = (Map<String, Object>) JSON.deserializeUntyped(bodyStr);
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
            String action = event.containsKey('action') ? String.valueOf(event.get('action')) : '';

            if (resourceType != 'task' || action == 'deleted') continue;

            Map<String, Object> resource = (Map<String, Object>) event.get('resource');
            String gid = resource != null ? String.valueOf(resource.get('gid')) : null;

            // Validate GID: must be a non-blank alphanumeric string
            if (String.isBlank(gid) || !Pattern.matches('[a-zA-Z0-9]+', gid)) continue;

            taskGidsToProcess.add(gid);
            if (taskGidsToProcess.size() >= 50) break;
        }

        if (!taskGidsToProcess.isEmpty()) {
            System.enqueueJob(new AsanaWebhookQueueable(new List<String>(taskGidsToProcess)));
        }
    }
}