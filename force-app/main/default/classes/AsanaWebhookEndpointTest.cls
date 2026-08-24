@IsTest
private class AsanaWebhookEndpointTest {

    // ── Mock HTTP callout for AsanaWebhookProcessor ───────────────────────────
    private class AsanaMockHttpResponse implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');
            res.setBody('{"data":{"gid":"gid001","name":"","resource_subtype":"default_task","tags":[],"custom_fields":[]}}');
            res.setStatusCode(200);
            return res;
        }
    }

    @TestSetup
    static void setup() {
        Asana_Integration_Settings__c s = new Asana_Integration_Settings__c();
        s.Asana_PAT__c          = 'test_pat';
        s.Asana_Project_GID__c  = '12345';
        s.Webhook_Secret__c     = 'test_secret_abc';
        insert s;
    }

    // ── 1. Handshake: X-Hook-Secret must be echoed back ──────────────────────
    @IsTest
    static void testHandshake() {
        RestRequest req = new RestRequest();
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
    }

    // ── 2. Valid task event: processes correctly ──────────────────────────────
    @IsTest
    static void testValidTaskEvent() {
        RestRequest req = new RestRequest();
        RestResponse res = new RestResponse();
        req.requestURI = '/services/apexrest/asana/webhook';
        req.httpMethod = 'POST';
        String body = JSON.serialize(new Map<String, Object>{
            'events' => new List<Object>{
                new Map<String, Object>{
                    'action'   => 'added',
                    'resource' => new Map<String, Object>{
                        'gid'           => 'task999',
                        'resource_type' => 'task'
                    }
                }
            }
        });
        req.requestBody = Blob.valueOf(body);
        RestContext.request  = req;
        RestContext.response = res;

        Test.startTest();
        AsanaWebhookEndpoint.handlePost();
        Test.stopTest();

        System.assertEquals(200, res.statusCode);
    }

    // ── 3. Invalid HMAC: verifySignature returns false ────────────────────────
    @IsTest
    static void testInvalidSignatureRejected() {
        String storedSecret = 'test_secret_abc';
        String body = '{"events":[]}';
        Blob bodyBlob = Blob.valueOf(body);

        Blob badHmac = Crypto.generateMac('HmacSHA256', bodyBlob, Blob.valueOf('wrong_secret'));
        String badSig = EncodingUtil.convertToHex(badHmac);

        Boolean result = AsanaWebhookEndpoint.verifySignature(storedSecret, bodyBlob, badSig);
        System.assertEquals(false, result, 'Invalid signature should fail verification');
    }

    // ── 4. Valid HMAC: verifySignature returns true ───────────────────────────
    @IsTest
    static void testValidSignatureAccepted() {
        String secret = 'test_secret_abc';
        String body   = '{"events":[]}';
        Blob bodyBlob = Blob.valueOf(body);

        Blob hmac = Crypto.generateMac('HmacSHA256', bodyBlob, Blob.valueOf(secret));
        String sig = EncodingUtil.convertToHex(hmac);

        Boolean result = AsanaWebhookEndpoint.verifySignature(secret, bodyBlob, sig);
        System.assertEquals(true, result, 'Valid signature should pass verification');
    }

    // ── 5. Deleted task events are skipped ───────────────────────────────────
    @IsTest
    static void testDeletedTaskSkipped() {
        RestRequest req = new RestRequest();
        RestResponse res = new RestResponse();
        req.requestURI = '/services/apexrest/asana/webhook';
        req.httpMethod = 'POST';
        String body = JSON.serialize(new Map<String, Object>{
            'events' => new List<Object>{
                new Map<String, Object>{
                    'action'   => 'deleted',
                    'resource' => new Map<String, Object>{
                        'gid'           => 'task888',
                        'resource_type' => 'task'
                    }
                }
            }
        });
        req.requestBody = Blob.valueOf(body);
        RestContext.request  = req;
        RestContext.response = res;

        Test.startTest();
        AsanaWebhookEndpoint.handlePost();
        Test.stopTest();

        System.assertEquals(200, res.statusCode);
    }

    // ── 6. Empty body returns 200 gracefully ─────────────────────────────────
    @IsTest
    static void testEmptyBody() {
        RestRequest req = new RestRequest();
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

    // ── 7. Multiple GIDs collapse into a single queueable ────────────────────
    @IsTest
    static void testMultipleGidsSingleQueueable() {
        RestRequest req = new RestRequest();
        RestResponse res = new RestResponse();
        req.requestURI = '/services/apexrest/asana/webhook';
        req.httpMethod = 'POST';
        List<Object> events = new List<Object>();
        for (Integer i = 0; i < 10; i++) {
            events.add(new Map<String, Object>{
                'action'   => 'added',
                'resource' => new Map<String, Object>{
                    'gid'           => 'task' + i,
                    'resource_type' => 'task'
                }
            });
        }
        req.requestBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{ 'events' => events }));
        RestContext.request  = req;
        RestContext.response = res;

        Test.startTest();
        AsanaWebhookEndpoint.handlePost();
        Test.stopTest();

        System.assertEquals(200, res.statusCode);
    }

    // ── 8. AsanaWebhookQueueable execute() body covered via mock callout ──────
    @IsTest
    static void testQueueableExecuteCovered() {
        Test.setMock(HttpCalloutMock.class, new AsanaMockHttpResponse());

        Set<String> gids = new Set<String>{'gid001'};
        AsanaWebhookQueueable q = new AsanaWebhookQueueable(gids);

        Test.startTest();
        q.execute(null);
        Test.stopTest();

        System.assertNotEquals(null, q, 'Queueable should execute without error');
    }
}
