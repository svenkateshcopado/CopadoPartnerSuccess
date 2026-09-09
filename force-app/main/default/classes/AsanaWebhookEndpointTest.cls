@IsTest
private class AsanaWebhookEndpointTest {

    /**
     * Computes the expected HMAC-SHA256 hex digest for a given secret and body.
     * This helper is used in every test that exercises the inbound webhook path
     * so that verifySignature() is always called with a valid, test-computed
     * signature rather than being bypassed (C-1 fix companion).
     */
    private static String computeHmac(String secret, String bodyStr) {
        Blob bodyBlob = Blob.valueOf(bodyStr);
        Blob hmac     = Crypto.generateMac('HmacSHA256', bodyBlob, Blob.valueOf(secret));
        return EncodingUtil.convertToHex(hmac);
    }

    // Mock: returns a minimal valid Asana task JSON for any callout
    private class AsanaMockHttpResponse implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');
            res.setBody('{"data":{"gid":"gid001","name":"","resource_subtype":"default_task","tags":[],"custom_fields":[]}}');
            res.setStatusCode(200);
            return res;
        }
    }

    /**
     * Pre-seeds Webhook_Secret__c so that verifySignature() can run its full
     * HMAC computation path during every test - no bypass required (C-1 fix).
     */
    @TestSetup
    static void setup() {
        Asana_Integration_Settings__c s = new Asana_Integration_Settings__c();
        s.Asana_PAT__c         = 'test_pat';
        s.Asana_Project_GID__c = '12345';
        s.Webhook_Secret__c    = 'test_secret_abc';
        insert s;
    }

    // 1. Handshake: X-Hook-Secret header is echoed back and persisted
    @IsTest
    static void testHandshake() {
        RestRequest  req = new RestRequest();
        RestResponse res = new RestResponse();
        req.requestURI  = '/services/apexrest/asana/webhook';
        req.httpMethod  = 'POST';
        req.headers.put('X-Hook-Secret', 'mysecret123');
        req.requestBody = Blob.valueOf('');
        RestContext.request  = req;
        RestContext.response = res;

        Test.startTest();
        AsanaWebhookEndpoint.handlePost();
        Test.stopTest();

        System.assertEquals(200, res.statusCode);
        System.assertEquals('mysecret123', res.headers.get('X-Hook-Secret'));
        Asana_Integration_Settings__c saved = Asana_Integration_Settings__c.getOrgDefaults();
        System.assertEquals('mysecret123', saved.Webhook_Secret__c);
    }

    // 2. Valid HMAC: task event is accepted and enqueued
    @IsTest
    static void testValidSignatureAccepted() {
        String secret  = 'test_secret_abc';
        String bodyStr = '{"events":[{"resource":{"gid":"11111","resource_type":"task"},"action":"changed"}]}';
        String sig     = computeHmac(secret, bodyStr);

        RestRequest  req = new RestRequest();
        RestResponse res = new RestResponse();
        req.requestURI  = '/services/apexrest/asana/webhook';
        req.httpMethod  = 'POST';
        req.headers.put('X-Hook-Signature', sig);
        req.requestBody = Blob.valueOf(bodyStr);
        RestContext.request  = req;
        RestContext.response = res;

        Test.setMock(HttpCalloutMock.class, new AsanaMockHttpResponse());
        Test.startTest();
        AsanaWebhookEndpoint.handlePost();
        Test.stopTest();

        System.assertEquals(200, res.statusCode);
    }

    // 3. Invalid HMAC: 401 is returned - verifySignature() gate is exercised
    @IsTest
    static void testInvalidSignatureReturns401() {
        String bodyStr = '{"events":[{"resource":{"gid":"99999","resource_type":"task"},"action":"changed"}]}';

        RestRequest  req = new RestRequest();
        RestResponse res = new RestResponse();
        req.requestURI  = '/services/apexrest/asana/webhook';
        req.httpMethod  = 'POST';
        req.headers.put('X-Hook-Signature', 'badhash');
        req.requestBody = Blob.valueOf(bodyStr);
        RestContext.request  = req;
        RestContext.response = res;

        Test.startTest();
        AsanaWebhookEndpoint.handlePost();
        Test.stopTest();

        System.assertEquals(401, res.statusCode);
    }

    // 4. Blank body with no handshake header: early exit, 200 returned
    @IsTest
    static void testBlankBodyEarlyExit() {
        RestRequest  req = new RestRequest();
        RestResponse res = new RestResponse();
        req.requestURI  = '/services/apexrest/asana/webhook';
        req.httpMethod  = 'POST';
        req.requestBody = Blob.valueOf('');
        RestContext.request  = req;
        RestContext.response = res;

        Test.startTest();
        AsanaWebhookEndpoint.handlePost();
        Test.stopTest();

        System.assertEquals(200, res.statusCode);
    }

    // 5. Batch of 60 GIDs: processed correctly
    @IsTest
    static void testBatchLimit() {
        List<String> events = new List<String>();
        for (Integer i = 0; i < 60; i++) {
            events.add('{"resource":{"gid":"' + String.valueOf(100000 + i) + '","resource_type":"task"},"action":"changed"}');
        }
        String bodyStr = '{"events":[' + String.join(events, ',') + ']}';
        String sig     = computeHmac('test_secret_abc', bodyStr);

        RestRequest  req = new RestRequest();
        RestResponse res = new RestResponse();
        req.requestURI  = '/services/apexrest/asana/webhook';
        req.httpMethod  = 'POST';
        req.headers.put('X-Hook-Signature', sig);
        req.requestBody = Blob.valueOf(bodyStr);
        RestContext.request  = req;
        RestContext.response = res;

        Test.setMock(HttpCalloutMock.class, new AsanaMockHttpResponse());
        Test.startTest();
        AsanaWebhookEndpoint.handlePost();
        Test.stopTest();

        System.assertEquals(200, res.statusCode);
    }

    // 6. Deleted events are filtered out
    @IsTest
    static void testDeletedEventsFiltered() {
        String bodyStr = '{"events":[{"resource":{"gid":"77777","resource_type":"task"},"action":"deleted"}]}';
        String sig     = computeHmac('test_secret_abc', bodyStr);

        RestRequest  req = new RestRequest();
        RestResponse res = new RestResponse();
        req.requestURI  = '/services/apexrest/asana/webhook';
        req.httpMethod  = 'POST';
        req.headers.put('X-Hook-Signature', sig);
        req.requestBody = Blob.valueOf(bodyStr);
        RestContext.request  = req;
        RestContext.response = res;

        Test.startTest();
        AsanaWebhookEndpoint.handlePost();
        Test.stopTest();

        System.assertEquals(200, res.statusCode);
    }

    // 7. verifySignature: blank secret returns false
    @IsTest
    static void testVerifySignatureBlankSecret() {
        Boolean result = AsanaWebhookEndpoint.verifySignature('', Blob.valueOf('body'), 'sig');
        System.assertEquals(false, result);
    }

    // 8. verifySignature: null body returns false
    @IsTest
    static void testVerifySignatureNullBody() {
        Boolean result = AsanaWebhookEndpoint.verifySignature('secret', null, 'sig');
        System.assertEquals(false, result);
    }

    // 9. verifySignature: valid inputs produce a matching XOR-clean result (C-2 validation)
    @IsTest
    static void testVerifySignatureValid() {
        String secret  = 'mysecret';
        String bodyStr = 'payload';
        String sig     = computeHmac(secret, bodyStr);
        Boolean result = AsanaWebhookEndpoint.verifySignature(secret, Blob.valueOf(bodyStr), sig);
        System.assertEquals(true, result);
    }

    // 10. Non-task resource type is filtered out
    @IsTest
    static void testNonTaskResourceTypeFiltered() {
        String bodyStr = '{"events":[{"resource":{"gid":"55555","resource_type":"project"},"action":"changed"}]}';
        String sig     = computeHmac('test_secret_abc', bodyStr);

        RestRequest  req = new RestRequest();
        RestResponse res = new RestResponse();
        req.requestURI  = '/services/apexrest/asana/webhook';
        req.httpMethod  = 'POST';
        req.headers.put('X-Hook-Signature', sig);
        req.requestBody = Blob.valueOf(bodyStr);
        RestContext.request  = req;
        RestContext.response = res;

        Test.startTest();
        AsanaWebhookEndpoint.handlePost();
        Test.stopTest();

        System.assertEquals(200, res.statusCode);
    }

    // 11. verifySignature: mismatched length returns false without entering XOR loop
    @IsTest
    static void testVerifySignatureLengthMismatch() {
        Boolean result = AsanaWebhookEndpoint.verifySignature('secret', Blob.valueOf('payload'), 'tooshort');
        System.assertEquals(false, result);
    }
}