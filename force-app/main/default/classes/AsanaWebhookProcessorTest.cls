@IsTest
private class AsanaWebhookProcessorTest {

    // ── Mock: full task with tag and custom field ──────────────────────────────────────────────────────────────────────────────────────────
    private class MockAsanaHttpFull implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"data":{"gid":"11111","name":"Test Task","resource_subtype":"default_task",' +
                '"tags":[{"gid":"t1","name":"copado"}],' +
                '"custom_fields":[{"name":"Sync","display_value":"Yes"}],' +
                '"notes":"Some description"}}');
            return res;
        }
    }

    // ── Mock: task with no tags/custom fields (tag filter mismatch) ────────────────────────────────────────────────
    private class MockAsanaHttpNoFilter implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"data":{"gid":"22222","name":"Unfiltered Task","resource_subtype":"default_task","tags":[],"custom_fields":[]}}');
            return res;
        }
    }

    // ── Mock: task with custom field match ────────────────────────────────────────────────────────────────────────────────────────────────────────────
    private class MockAsanaHttpCustomField implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"data":{"gid":"33333","name":"CF Task","resource_subtype":"default_task",' +
                '"tags":[],' +
                '"custom_fields":[{"name":"Status","display_value":"Active"}]}}');
            return res;
        }
    }

    // ── Mock: task with custom field mismatch ─────────────────────────────────────────────────────────────────────────────────────────────────────────
    private class MockAsanaHttpCustomFieldMismatch implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"data":{"gid":"44444","name":"CF Mismatch Task","resource_subtype":"default_task",' +
                '"tags":[],' +
                '"custom_fields":[{"name":"Status","display_value":"Pending"}]}}');
            return res;
        }
    }

    // ── Mock: Asana API 401 error ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
    private class MockAsanaHttpError implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(401);
            res.setBody('{"error":"Unauthorized"}');
            return res;
        }
    }

    // ── Mock: null data node ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
    private class MockAsanaHttpNullData implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"data":null}');
            return res;
        }
    }

    // ── Mock: task with resource_subtype to exercise RT resolution ────────────────────────────────────────────────
    private class MockAsanaHttpSubtype implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"data":{"gid":"55555","name":"Subtype Task","resource_subtype":"milestone",' +
                '"tags":[{"gid":"t1","name":"copado"}],' +
                '"custom_fields":[]}}');
            return res;
        }
    }

    // ── Mock: webhook registration success ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
    private class MockRegistrationSuccess implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(201);
            res.setBody('{"data":{"gid":"webhook001","secret":"asana_webhook_secret_from_api","resource":{"gid":"proj123"},"target":"https://example.com"}}');
            return res;
        }
    }

    // ── Mock: webhook registration failure ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
    private class MockRegistrationFail implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(400);
            res.setBody('{"error":"Bad Request"}');
            return res;
        }
    }

    @TestSetup
    static void setup() {
        Asana_Integration_Settings__c s = new Asana_Integration_Settings__c();
        s.Asana_PAT__c         = 'test_pat';
        s.Asana_Project_GID__c = 'proj123';
        s.Webhook_Secret__c    = 'test_secret';
        s.Filter_By_Tag__c     = 'copado';
        insert s;
    }

    // Finding 4: Invalid GIDs must be rejected at the processor level.
    @IsTest
    static void testProcessTaskEventRejectsNonNumericGid() {
        Test.setMock(HttpCalloutMock.class, new MockAsanaHttpError());
        Test.startTest();
        AsanaWebhookProcessor.processTaskEvent('../users/me');
        AsanaWebhookProcessor.processTaskEvent('abc');
        AsanaWebhookProcessor.processTaskEvent('');
        AsanaWebhookProcessor.processTaskEvent(null);
        Test.stopTest();
        System.assertEquals(0, [SELECT COUNT() FROM copado__User_Story__c],
            'No User Stories should be created for invalid GIDs');
    }

    // Happy path: tag-filtered task is upserted as a User Story
    @IsTest
    static void testProcessTaskEventSuccess() {
        Test.setMock(HttpCalloutMock.class, new MockAsanaHttpFull());
        Test.startTest();
        AsanaWebhookProcessor.processTaskEvent('11111');
        Test.stopTest();
    }

    // Task that does not match tag filter must be skipped
    @IsTest
    static void testProcessTaskEventTagFilterMismatch() {
        Test.setMock(HttpCalloutMock.class, new MockAsanaHttpNoFilter());
        Test.startTest();
        AsanaWebhookProcessor.processTaskEvent('22222');
        Test.stopTest();
        System.assertEquals(0, [SELECT COUNT() FROM copado__User_Story__c],
            'Tasks not matching the tag filter must not create User Stories');
    }

    // Custom field filter: value match
    @IsTest
    static void testProcessTaskEventCustomFieldFilter() {
        Asana_Integration_Settings__c s = Asana_Integration_Settings__c.getOrgDefaults();
        s.Filter_By_Tag__c              = null;
        s.Filter_Custom_Field_Name__c   = 'Status';
        s.Filter_Custom_Field_Value__c  = 'Active';
        update s;
        Test.setMock(HttpCalloutMock.class, new MockAsanaHttpCustomField());
        Test.startTest();
        AsanaWebhookProcessor.processTaskEvent('33333');
        Test.stopTest();
    }

    // Custom field filter: value mismatch must skip upsert
    @IsTest
    static void testProcessTaskEventCustomFieldFilterMismatch() {
        Asana_Integration_Settings__c s = Asana_Integration_Settings__c.getOrgDefaults();
        s.Filter_By_Tag__c              = null;
        s.Filter_Custom_Field_Name__c   = 'Status';
        s.Filter_Custom_Field_Value__c  = 'Active';
        update s;
        Test.setMock(HttpCalloutMock.class, new MockAsanaHttpCustomFieldMismatch());
        Test.startTest();
        AsanaWebhookProcessor.processTaskEvent('44444');
        Test.stopTest();
        System.assertEquals(0, [SELECT COUNT() FROM copado__User_Story__c],
            'Custom field value mismatch must not create User Stories');
    }

    // Asana API error must not create a User Story
    @IsTest
    static void testProcessTaskEventApiError() {
        Test.setMock(HttpCalloutMock.class, new MockAsanaHttpError());
        Test.startTest();
        AsanaWebhookProcessor.processTaskEvent('99999');
        Test.stopTest();
        System.assertEquals(0, [SELECT COUNT() FROM copado__User_Story__c],
            'API errors must not create User Stories');
    }

    // Null data node in Asana response must be handled gracefully
    @IsTest
    static void testProcessTaskEventNullData() {
        Test.setMock(HttpCalloutMock.class, new MockAsanaHttpNullData());
        Test.startTest();
        AsanaWebhookProcessor.processTaskEvent('77777');
        Test.stopTest();
        System.assertEquals(0, [SELECT COUNT() FROM copado__User_Story__c],
            'Null data node must not create User Stories');
    }

    // Settings not configured must exit early without callout
    @IsTest
    static void testProcessTaskEventNoSettings() {
        delete [SELECT Id FROM Asana_Integration_Settings__c];
        Test.setMock(HttpCalloutMock.class, new MockAsanaHttpError());
        Test.startTest();
        AsanaWebhookProcessor.processTaskEvent('66666');
        Test.stopTest();
        System.assertEquals(0, [SELECT COUNT() FROM copado__User_Story__c],
            'Missing settings must not create User Stories');
    }

    // Subtype-based record type resolution exercises the RT mapping path
    @IsTest
    static void testProcessTaskEventSubtypeRecordType() {
        Test.setMock(HttpCalloutMock.class, new MockAsanaHttpSubtype());
        Test.startTest();
        AsanaWebhookProcessor.processTaskEvent('55555');
        Test.stopTest();
    }

    // Finding 1 trust chain: webhook GID is saved from the authenticated API response.
    @IsTest
    static void testWebhookRegistrationSuccess() {
        Asana_Integration_Settings__c s = Asana_Integration_Settings__c.getOrgDefaults();
        s.Webhook_GID__c = null;
        update s;

        Test.setMock(HttpCalloutMock.class, new MockRegistrationSuccess());
        Test.startTest();
        AsanaWebhookRegistration.registerWebhook();
        Test.stopTest();

        Asana_Integration_Settings__c settings = Asana_Integration_Settings__c.getOrgDefaults();
        System.assertEquals('webhook001', settings.Webhook_GID__c,
            'Webhook GID must be saved from the authenticated API response');
    }

    // Registration failure must not update settings
    @IsTest
    static void testWebhookRegistrationFail() {
        Test.setMock(HttpCalloutMock.class, new MockRegistrationFail());
        String originalSecret = Asana_Integration_Settings__c.getOrgDefaults().Webhook_Secret__c;
        Test.startTest();
        AsanaWebhookRegistration.registerWebhook();
        Test.stopTest();
        Asana_Integration_Settings__c settings = Asana_Integration_Settings__c.getOrgDefaults();
        System.assertEquals(originalSecret, settings.Webhook_Secret__c,
            'Failed registration must not modify the stored secret');
    }

    // Registration: missing project GID must exit early without making a callout
    @IsTest
    static void testWebhookRegistrationMissingProjectGid() {
        Asana_Integration_Settings__c s = Asana_Integration_Settings__c.getOrgDefaults();
        s.Asana_Project_GID__c = null;
        update s;
        // No mock set intentionally: confirms no callout is attempted
        AsanaWebhookRegistration.registerWebhook();
    }
}