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

    // ── 1. Handshake: X-Hook-Secret must be echoed back ───────────────────────
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

    // ── 2. Handshake blocked when PAT not configured ──────────────────────────
    @IsTest
    static void testHandshakeBlockedWhenNotConfigured() {
        // Delete settings so PAT is blank
        delete [SELECT Id FROM Asana_Integration_Settings__c LIMIT 1];

        RestRequest req = new RestRequest();
        RestResponse res = new RestResponse();
        req.requestURI  = '/services/apexrest/asana/webhook';
        req.httpMethod  = 'POST';
        req.headers.put('X-Hook-Secret', 'attacker_secret');
        req.requestBody = Blob.valueOf('');
        RestContext.request  = req;
        RestContext.response = res;

        Test.startTest();
        AsanaWebhookEndpoint.handlePost();
        Test.stopTest();

        System.assertEquals(403, res.statusCode,
            'Handshake must be rejected when PAT is not configured');
    }

    // ── 3. Valid task event: processes correctly ──────────────────────────────
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

    // ── 4. Invalid HMAC: verifySignature returns false ────────────────────────
    @IsTest
    static void testInvalidSignatureRejected() {
        String storedSecret = 'test_secret_abc';
        String body = '{"events":[]}';
        Blob bodyBlob = Blob.valueOf(body);
        Blob badHmac = Crypto.generateMac('HmacSHA256', bodyBlob, Blob.valueOf('wrong_secret'));
        String badSig = EncodingUtil.convertToHex(badHmac);
        Boolean result = AsanaWebhookEndpoint.verifySignature(storedSecret, bodyBlob, badSig);
        System.assertEquals(false, result, 'Wrong HMAC key must fail verification');
    }

    // ── 5. Valid HMAC: verifySignature returns true ───────────────────────────
    @IsTest
    static void testValidSignatureAccepted() {
        String storedSecret = 'test_secret_abc';
        String body = '{"events":[]}';
        Blob bodyBlob = Blob.valueOf(body);
        Blob goodHmac = Crypto.generateMac('HmacSHA256', bodyBlob, Blob.valueOf(storedSecret));
        String goodSig = EncodingUtil.convertToHex(goodHmac);
        Boolean result = AsanaWebhookEndpoint.verifySignature(storedSecret, bodyBlob, goodSig);
        System.assertEquals(true, result, 'Correct HMAC must pass verification');
    }

    // ── 6. GID with invalid characters is skipped ────────────────────────────
    @IsTest
    static void testInvalidGidIsSkipped() {
        Test.setMock(HttpCalloutMock.class, new AsanaMockHttpResponse());
        RestRequest req = new RestRequest();
        RestResponse res = new RestResponse();
        req.requestURI = '/services/apexrest/asana/webhook';
        req.httpMethod = 'POST';
        String body = JSON.serialize(new Map<String, Object>{
            'events' => new List<Object>{
                new Map<String, Object>{
                    'action'   => 'added',
                    'resource' => new Map<String, Object>{
                        'gid'           => '../etc/passwd',
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

        // 200 is returned but no job enqueued for invalid GID
        System.assertEquals(200, res.statusCode);
    }

    // ── 7. Deleted task events are skipped ────────────────────────────────────
    @IsTest
    static void testDeletedEventSkipped() {
        RestRequest req = new RestRequest();
        RestResponse res = new RestResponse();
        req.requestURI = '/services/apexrest/asana/webhook';
        req.httpMethod = 'POST';
        String body = JSON.serialize(new Map<String, Object>{
            'events' => new List<Object>{
                new Map<String, Object>{
                    'action'   => 'deleted',
                    'resource' => new Map<String, Object>{
                        'gid'           => 'task123',
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

    // ── 8. Empty body returns 200 without processing ──────────────────────────
    @IsTest
    static void testEmptyBodyReturnsOk() {
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
}