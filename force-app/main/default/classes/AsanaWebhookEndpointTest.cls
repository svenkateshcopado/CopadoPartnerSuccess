@IsTest
private class AsanaWebhookEndpointTest {

    @TestSetup
    static void setup() {
        Asana_Integration_Settings__c s = new Asana_Integration_Settings__c();
        s.Asana_PAT__c = 'test_pat';
        s.Asana_Project_GID__c = '12345';
        insert s;
    }

    @IsTest
    static void testHandshake() {
        RestRequest req = new RestRequest();
        RestResponse res = new RestResponse();
        req.requestURI = '/services/apexrest/asana/webhook';
        req.httpMethod = 'POST';
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

    @IsTest
    static void testValidTaskEvent() {
        RestRequest req = new RestRequest();
        RestResponse res = new RestResponse();
        req.requestURI = '/services/apexrest/asana/webhook';
        req.httpMethod = 'POST';
        String body = JSON.serialize(new Map<String, Object>{
            'events' => new List<Object>{
                new Map<String, Object>{
                    'action' => 'added',
                    'resource' => new Map<String, Object>{
                        'gid' => 'task999',
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

    @IsTest
    static void testDeletedTaskSkipped() {
        RestRequest req = new RestRequest();
        RestResponse res = new RestResponse();
        req.requestURI = '/services/apexrest/asana/webhook';
        req.httpMethod = 'POST';
        String body = JSON.serialize(new Map<String, Object>{
            'events' => new List<Object>{
                new Map<String, Object>{
                    'action' => 'deleted',
                    'resource' => new Map<String, Object>{
                        'gid' => 'task888',
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

    @IsTest
    static void testEmptyBody() {
        RestRequest req = new RestRequest();
        RestResponse res = new RestResponse();
        req.requestURI = '/services/apexrest/asana/webhook';
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf('');
        RestContext.request  = req;
        RestContext.response = res;
        Test.startTest();
        AsanaWebhookEndpoint.handlePost();
        Test.stopTest();
        System.assertEquals(200, res.statusCode);
    }
}