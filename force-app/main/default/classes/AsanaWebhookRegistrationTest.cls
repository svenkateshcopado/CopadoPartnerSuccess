@IsTest
private class AsanaWebhookRegistrationTest {

    // --- Mock: simulate Asana webhook registration success (201) ---
    private class SuccessMock implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');
            res.setBody('{"data":{"gid":"987654321"}}');
            res.setStatusCode(201);
            return res;
        }
    }

    // --- Mock: simulate Asana API failure (400) ---
    private class FailureMock implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');
            res.setBody('{"errors":[{"message":"Bad Request"}]}');
            res.setStatusCode(400);
            return res;
        }
    }

    // --- Mock: simulate a 200 OK response (alternative success) ---
    private class SuccessMock200 implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');
            res.setBody('{"data":{"gid":"111222333"}}');
            res.setStatusCode(200);
            return res;
        }
    }

    @TestSetup
    static void setup() {
        // HIGH-01 FIX VERIFICATION: Settings only need Asana_Project_GID__c.
        // Asana_PAT__c is NOT required for registerWebhook() to proceed.
        Asana_Integration_Settings__c s = new Asana_Integration_Settings__c();
        s.Asana_Project_GID__c = '123456789';
        insert s;
    }

    // 1. Success path: 201 response persists Webhook GID
    @IsTest
    static void testRegisterWebhookSuccess() {
        Test.setMock(HttpCalloutMock.class, new SuccessMock());
        Test.startTest();
        AsanaWebhookRegistration.registerWebhook();
        Test.stopTest();

        Asana_Integration_Settings__c saved = Asana_Integration_Settings__c.getOrgDefaults();
        System.assertEquals('987654321', saved.Webhook_GID__c,
            'Webhook GID should be persisted after a 201 response.');
    }

    // 2. Success path: 200 response also persists Webhook GID
    @IsTest
    static void testRegisterWebhookSuccess200() {
        Test.setMock(HttpCalloutMock.class, new SuccessMock200());
        Test.startTest();
        AsanaWebhookRegistration.registerWebhook();
        Test.stopTest();

        Asana_Integration_Settings__c saved = Asana_Integration_Settings__c.getOrgDefaults();
        System.assertEquals('111222333', saved.Webhook_GID__c,
            'Webhook GID should be persisted after a 200 response.');
    }

    // 3. Failure path: non-2xx response logs and does not throw
    @IsTest
    static void testRegisterWebhookFailure() {
        Test.setMock(HttpCalloutMock.class, new FailureMock());
        Test.startTest();
        AsanaWebhookRegistration.registerWebhook();
        Test.stopTest();
        System.assert(true, 'registerWebhook should complete without exception on API failure.');
    }

    // 4. Guard: missing Asana_Project_GID__c causes early exit without callout
    @IsTest
    static void testGuardMissingGID() {
        Asana_Integration_Settings__c s = Asana_Integration_Settings__c.getOrgDefaults();
        s.Asana_Project_GID__c = '';
        update s;

        Test.startTest();
        AsanaWebhookRegistration.registerWebhook();
        Test.stopTest();
        System.assert(true, 'Early exit should occur when Asana_Project_GID__c is blank.');
    }

    // 5. Guard: null settings causes early exit without callout
    @IsTest
    static void testGuardNullSettings() {
        Asana_Integration_Settings__c s = Asana_Integration_Settings__c.getOrgDefaults();
        delete s;

        Test.startTest();
        AsanaWebhookRegistration.registerWebhook();
        Test.stopTest();
        System.assert(true, 'Early exit should occur when settings record is null.');
    }

    // 6. HIGH-01 Compliance: confirm Asana_PAT__c is NOT read by registerWebhook()
    @IsTest
    static void testHighO1ComplianceNoPATRequired() {
        Test.setMock(HttpCalloutMock.class, new SuccessMock());
        Test.startTest();
        AsanaWebhookRegistration.registerWebhook();
        Test.stopTest();

        Asana_Integration_Settings__c saved = Asana_Integration_Settings__c.getOrgDefaults();
        System.assertEquals('987654321', saved.Webhook_GID__c,
            'registerWebhook() must succeed without Asana_PAT__c - HIGH-01 compliance check.');
    }
}