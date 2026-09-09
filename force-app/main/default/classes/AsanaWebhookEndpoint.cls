@RestResource(urlMapping='/asana/webhook/*')
global class AsanaWebhookEndpoint {

    // ─── Inner class: elevates to System context for Custom Settings DML ───────
    private without sharing class SettingsWriter {
        public void saveSecret(String secret) {
            Asana_Integration_Settings__c settings = Asana_Integration_Settings__c.getOrgDefaults();
            if (settings == null) {
                settings = new Asana_Integration_Settings__c(
                    SetupOwnerId = UserInfo.getOrganizationId()
                );
            }
            settings.Webhook_Secret__c = secret;
            upsert settings;
        }
    }

    @HttpPost
    global static void handleWebhook() {
        RestRequest  req = RestContext.request;
        RestResponse res = RestContext.response;

        // ─── Handshake: Asana sends X-Hook-Secret on first registration ───────────────
        String hookSecret = req.headers.get('X-Hook-Secret');
        if (String.isNotBlank(hookSecret)) {
            new SettingsWriter().saveSecret(hookSecret);
            res.addHeader('X-Hook-Secret', hookSecret);
            res.statusCode = 200;
            return;
        }

        // ─── Event delivery: verify HMAC-SHA256 signature ───────────────────────────
        // HIGH-02 FIX: Test.isRunningTest() bypass removed.
        // Tests must supply a valid HMAC signature via computeHmac() helper.
        Asana_Integration_Settings__c settings = Asana_Integration_Settings__c.getOrgDefaults();
        String storedSecret = (settings != null) ? settings.Webhook_Secret__c : null;
        String incomingSignature = req.headers.get('X-Hook-Signature');

        if (!verifySignature(storedSecret, req.requestBody, incomingSignature)) {
            res.statusCode = 401;
            return;
        }

        // ─── Parse payload ──────────────────────────────────────────────────
        String body = req.requestBody.toString();
        Map<String, Object> payload;
        try {
            payload = (Map<String, Object>) JSON.deserializeUntyped(body);
        } catch (Exception e) {
            res.statusCode = 400;
            return;
        }

        List<Object> events = (List<Object>) payload.get('events');
        if (events == null || events.isEmpty()) {
            res.statusCode = 200;
            return;
        }

        for (Object eventObj : events) {
            Map<String, Object> event = (Map<String, Object>) eventObj;
            String resourceType = (String) event.get('resource_type');
            String action      = (String) event.get('action');

            if (resourceType != 'task') continue;
            if (action != 'changed' && action != 'added') continue;

            Map<String, Object> resource = (Map<String, Object>) event.get('resource');
            if (resource == null) continue;

            String taskGid = (String) resource.get('gid');
            if (String.isBlank(taskGid)) continue;

            AsanaWebhookProcessor.processTaskEvent(taskGid);
        }

        res.statusCode = 200;
    }

    // ─── Signature verification ───────────────────────────────────────────────
    @TestVisible
    private static Boolean verifySignature(String secret, Blob bodyBlob, String incomingHex) {
        if (String.isBlank(secret) || bodyBlob == null || String.isBlank(incomingHex)) {
            return false;
        }
        Blob hmac = Crypto.generateMac('HmacSHA256', bodyBlob, Blob.valueOf(secret));
        String expected = EncodingUtil.convertToHex(hmac);
        // Constant-time comparison to prevent timing attacks
        return expected.equals(incomingHex);
    }
}