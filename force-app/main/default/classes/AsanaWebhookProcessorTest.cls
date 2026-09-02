@IsTest
private class AsanaWebhookProcessorTest {

    // ── Mock: full task with tag and custom field ─────────────────────────────
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

    // ── Mock: task with no tags/custom fields (tag filter mismatch) ───────────
    private class MockAsanaHttpNoFilter implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"data":{"gid":"22222","name":"Unfiltered Task","resource_subtype":"default_task","tags":[],"custom_fields":[]}}');
            return res;
        }
    }

    // ── Mock: task with custom field match ────────────────────────────────────
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

    // ── Mock: task with custom field mismatch ─────────────────────────────────
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

    // ── Mock: Asana API 401 error ─────────────────────────────────────────────
    private class MockAsanaHttpError implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(401);
            res.setBody('{"error":"Unauthorized"}');
            return res;
        }
    }

    // ── Mock: null data node ──────────────────────────────────────────────────
    private class MockAsanaHttpNullData implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"data":null}');
            return res;
        }
    }

    // ── Mock: task with empty name ────────────────────────────────────────────
    private class MockAsanaHttpEmptyName implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"data":{"gid":"77777","name":"","resource_subtype":"default_task","tags":[],"custom_fields":[]}}');
            return res;
        }
    }

    // ── Mock: task for invalid GID test (should never be called) ─────────────
    private class MockAsanaHttpInvalidGid implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"data":{"gid":"99999","name":"Should Not Reach","resource_subtype":"default_task","tags":[],"custom_fields":[]}}');
            return res;
        }
    }

    @TestSetup
    static void setup() {
        Asana_Integration_Settings__c s = new Asana_Integration_Settings__c();
        s.Asana_PAT__c              = 'test_pat';
        s.Asana_Project_GID__c      = '12345';
        s.Webhook_Secret__c         = 'test_secret';
        s.Filter_By_Tag__c          = 'copado';
        s.Filter_Custom_Field_Name__c  = 'Sync';
        s.Filter_Custom_Field_Value__c = 'Yes';
        insert s;
    }

    // ── 1. Full task matching tag and custom field filter syncs to Copado ─────
    @IsTest
    static void testProcessTaskEventSuccess() {
        Test.setMock(HttpCalloutMock.class, new MockAsanaHttpFull());
        Test.startTest();
        AsanaWebhookProcessor.processTaskEvent('11111');
        Test.stopTest();
        List<copado__User_Story__c> stories = [SELECT Id, Asana_Task_ID__c FROM copado__User_Story__c WHERE Asana_Task_ID__c = '11111'];
        System.assertEquals(1, stories.size(), 'User story should have been created');
    }

    // ── 2. Tag filter mismatch: task not synced ───────────────────────────────
    @IsTest
    static void testTagFilterMismatch() {
        Test.setMock(HttpCalloutMock.class, new MockAsanaHttpNoFilter());
        Test.startTest();
        AsanaWebhookProcessor.processTaskEvent('22222');
        Test.stopTest();
        List<copado__User_Story__c> stories = [SELECT Id FROM copado__User_Story__c WHERE Asana_Task_ID__c = '22222'];
        System.assertEquals(0, stories.size(), 'Task without matching tag must not be synced');
    }

    // ── 3. Custom field filter match: task synced ─────────────────────────────
    @IsTest
    static void testCustomFieldFilterMatch() {
        // Remove tag filter so only custom field filter applies
        Asana_Integration_Settings__c s = Asana_Integration_Settings__c.getOrgDefaults();
        s.Filter_By_Tag__c = null;
        update s;
        Test.setMock(HttpCalloutMock.class, new MockAsanaHttpCustomField());
        Test.startTest();
        AsanaWebhookProcessor.processTaskEvent('33333');
        Test.stopTest();
        List<copado__User_Story__c> stories = [SELECT Id FROM copado__User_Story__c WHERE Asana_Task_ID__c = '33333'];
        System.assertEquals(1, stories.size(), 'Task matching custom field filter must be synced');
    }

    // ── 4. Custom field filter mismatch: task not synced ──────────────────────
    @IsTest
    static void testCustomFieldFilterMismatch() {
        Asana_Integration_Settings__c s = Asana_Integration_Settings__c.getOrgDefaults();
        s.Filter_By_Tag__c = null;
        s.Filter_Custom_Field_Value__c = 'Active';
        update s;
        Test.setMock(HttpCalloutMock.class, new MockAsanaHttpCustomFieldMismatch());
        Test.startTest();
        AsanaWebhookProcessor.processTaskEvent('44444');
        Test.stopTest();
        List<copado__User_Story__c> stories = [SELECT Id FROM copado__User_Story__c WHERE Asana_Task_ID__c = '44444'];
        System.assertEquals(0, stories.size(), 'Custom field value mismatch must skip the task');
    }

    // ── 5. Asana API error: no exception thrown, graceful exit ────────────────
    @IsTest
    static void testApiError() {
        Test.setMock(HttpCalloutMock.class, new MockAsanaHttpError());
        Test.startTest();
        AsanaWebhookProcessor.processTaskEvent('55555');
        Test.stopTest();
        List<copado__User_Story__c> stories = [SELECT Id FROM copado__User_Story__c WHERE Asana_Task_ID__c = '55555'];
        System.assertEquals(0, stories.size());
    }

    // ── 6. Null data node: no exception thrown ────────────────────────────────
    @IsTest
    static void testNullDataNode() {
        Test.setMock(HttpCalloutMock.class, new MockAsanaHttpNullData());
        Test.startTest();
        AsanaWebhookProcessor.processTaskEvent('66666');
        Test.stopTest();
        System.assertEquals(0, [SELECT COUNT() FROM copado__User_Story__c WHERE Asana_Task_ID__c = '66666']);
    }

    // ── 7. Empty task name: not synced ────────────────────────────────────────
    @IsTest
    static void testEmptyTaskNameSkipped() {
        Test.setMock(HttpCalloutMock.class, new MockAsanaHttpEmptyName());
        Test.startTest();
        AsanaWebhookProcessor.processTaskEvent('77777');
        Test.stopTest();
        System.assertEquals(0, [SELECT COUNT() FROM copado__User_Story__c WHERE Asana_Task_ID__c = '77777']);
    }

    // ── 8. Blank GID: method returns immediately ──────────────────────────────
    @IsTest
    static void testBlankGid() {
        Test.startTest();
        AsanaWebhookProcessor.processTaskEvent(null);
        AsanaWebhookProcessor.processTaskEvent('');
        Test.stopTest();
        System.assertEquals(0, [SELECT COUNT() FROM copado__User_Story__c]);
    }

    // ── 9. Invalid GID format: rejected before callout ────────────────────────
    @IsTest
    static void testInvalidGidFormat() {
        Test.setMock(HttpCalloutMock.class, new MockAsanaHttpInvalidGid());
        Test.startTest();
        AsanaWebhookProcessor.processTaskEvent('../etc/passwd');
        AsanaWebhookProcessor.processTaskEvent('task-id-with-dashes');
        Test.stopTest();
        // No user stories created, no exceptions thrown
        System.assertEquals(0, [SELECT COUNT() FROM copado__User_Story__c]);
    }

    // ── 10. No settings configured: returns gracefully ────────────────────────
    @IsTest
    static void testNoSettingsConfigured() {
        delete [SELECT Id FROM Asana_Integration_Settings__c LIMIT 1];
        Test.startTest();
        AsanaWebhookProcessor.processTaskEvent('88888');
        Test.stopTest();
        System.assertEquals(0, [SELECT COUNT() FROM copado__User_Story__c WHERE Asana_Task_ID__c = '88888']);
    }
}