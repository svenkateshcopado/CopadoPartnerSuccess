@IsTest
private class AsanaWebhookEndpointTest {

    private static String computeHmac(String secret, String bodyStr) {
        Blob hmac = Crypto.generateMac('HmacSHA256', Blob.valueOf(bodyStr), Blob.valueOf(secret));
        return EncodingUtil.convertToHex(hmac);
    }

    // Mock that returns a minimal valid Asana task
    private class AsanaMockHttpResponse implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');
            res.setBody('{"data":{"gid":"99999","name":"Test Task","resource_subtype":"default_task","notes":"","due_on":null,"assignee":null,"tags":[],"custom_fields":[],"memberships":[]}}');
            res.setStatusCode(200);
            return res;
        }
    }

    @TestSetup
    static void setup() {
        Asana_Integration_Settings__c s = new Asana_Integration_Settings__c(
            SetupOwnerId        = UserInfo.getOrganizationId(),
            Asana_Project_GID__c = '123456789',
            Webhook_Secret__c   = 'test-secret-key'
        );
        insert s;
    }

    // HIGH-02 FIX: Tests now compute and supply a real HMAC signature.
    // No Test.isRunningTest() bypass is used.
    @IsTest
    static void testValidWebhookEvent() {
        String secret  = 'test-secret-key';
        String body    = '{"events":[{"resource_type":"task","action":"changed","resource":{"gid":"99999"}}]}';
        String sigHex  = computeHmac(secret, body);

        RestRequest req = new RestRequest();
        req.requestURI = '/services/apexrest/asana/webhook/';
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf(body);
        req.headers.put('X-Hook-Signature', sigHex);

        RestContext.request  = req;
        RestContext.response = new RestResponse();

        Test.setMock(HttpCalloutMock.class, new AsanaMockHttpResponse());
        Test.startTest();
        AsanaWebhookEndpoint.handleWebhook();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode);
    }

    @IsTest
    static void testInvalidSignatureReturns401() {
        String body = '{"events":[{"resource_type":"task","action":"changed","resource":{"gid":"99999"}}]}';

        RestRequest req = new RestRequest();
        req.requestURI = '/services/apexrest/asana/webhook/';
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf(body);
        req.headers.put('X-Hook-Signature', 'badhex000000000000000000000000000000000000000000000000000000000000');

        RestContext.request  = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        AsanaWebhookEndpoint.handleWebhook();
        Test.stopTest();

        System.assertEquals(401, RestContext.response.statusCode);
    }

    @IsTest
    static void testHandshake() {
        RestRequest req = new RestRequest();
        req.requestURI = '/services/apexrest/asana/webhook/';
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf('');
        req.headers.put('X-Hook-Secret', 'handshake-secret-value');

        RestContext.request  = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        AsanaWebhookEndpoint.handleWebhook();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals('handshake-secret-value', RestContext.response.headers.get('X-Hook-Secret'));
    }

    @IsTest
    static void testVerifySignatureDirect() {
        String secret = 'my-secret';
        String body   = 'hello world';
        Blob   hmac   = Crypto.generateMac('HmacSHA256', Blob.valueOf(body), Blob.valueOf(secret));
        String hex    = EncodingUtil.convertToHex(hmac);

        System.assert(AsanaWebhookEndpoint.verifySignature(secret, Blob.valueOf(body), hex),   'Valid HMAC should pass');
        System.assert(!AsanaWebhookEndpoint.verifySignature(secret, Blob.valueOf(body), 'bad'), 'Bad HMAC should fail');
        System.assert(!AsanaWebhookEndpoint.verifySignature(null,   Blob.valueOf(body), hex),   'Null secret should fail');
        System.assert(!AsanaWebhookEndpoint.verifySignature(secret, null,               hex),   'Null body should fail');
    }
}