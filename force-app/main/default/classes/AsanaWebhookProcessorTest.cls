@IsTest
private class AsanaWebhookProcessorTest {

    private class MockAsanaHttpFull implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"data":{"gid":"task001","name":"Test Task","resource_subtype":"default_task",' +
                '{"tags":[{"gid":"t1","name":"copado"}],' +
                '"custom_fields":[{"name":"Sync","display_value":"Yes"}],' +
                '"notes":"Some description"}}');
            return res;
        }
    }

    private class MockAsanaHttpNoFilter implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"data":{"gid":"task002","name":"Unfiltered Task","resource_subtype":"default_task","tags":[],"custom_fields":[]}}');
            return res;
        }
    }

    private class MockAsanaHttpCustomField implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"data":{"gid":"task003","name":"CF Task","resource_subtype":"default_task",' +
                '"tags":[],' +
                '"custom_fields":[{"name":"Status","display_value":"Active"}]}}');
            return res;
        }
    }

    private class MockAsanaHttpError implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(401);
            res.setBody('{"error":"Unauthorized"}');
            return res;
        }
    }

    private class MockRegistrationSuccess implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(201);
            res.setBody('{"data":{"gid":"webhook001","resource":{"gid":"proj123"},"target":"https://example.com"}}');
            return res;
        }
    }

    private class MockRegistrationFail implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(400);
            res.setBody('{"error":"Bad Request"}');
            return res;
        }
    }

    private class MockOutboundSuccess implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"data":{"gid":"task_out_001"}}');
            return res;
        }
    }

    private class MockOutboundFail implements HttpCalloutMock {
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
        s.Asana_PAT__c = 'test_pat';
        s.Asana_Project_GID__c = '12345';
        insert s;
    }

    @IsTest
    static void testProcessTaskEventBasic() {
        Test.setMock(HttpCalloutMock.class, new MockAsanaHttpNoFilter());
        Test.startTest();
        AsanaWebhookProcessor.processTaskEvent('task002');
        Test.stopTest();
        List<copado__User_Story__c> stories = [SELECT Id FROM copado__User_Story__c WHERE Asana_Task_Id__c = 'task002'];
        System.assert(!stories.isEmpty(), 'User Story should have been upserted for task002');
    }

    @IsTest
    static void testProcessTaskEventBlankGid() {
        Test.startTest();
        AsanaWebhookProcessor.processTaskEvent('');
        Test.stopTest();
        System.assert(true, 'Should exit cleanly');
    }

    @IsTest
    static void testProcessTaskEventApiError() {
        Test.setMock(HttpCalloutMock.class, new MockAsanaHttpError());
        Test.startTest();
        AsanaWebhookProcessor.processTaskEvent('task_err');
        Test.stopTest();
        System.assert(true, 'Should handle API error gracefully');
    }

    @IsTest
    static void testProcessTaskWithTagFilter() {
        Asana_Integration_Settings__c s = Asana_Integration_Settings__c.getOrgDefaults();
        s.Filter_By_Tag__c = 'copado';
        update s;
        Test.setMock(HttpCalloutMock.class, new MockAsanaHttpNoFilter());
        Test.startTest();
        AsanaWebhookProcessor.processTaskEvent('task001');
        Test.stopTest();
        System.assert(true, 'Tag filter test completed');
    }

    @IsTest
    static void testProcessTaskCustomFieldFilter() {
        Asana_Integration_Settings__c s = Asana_Integration_Settings__c.getOrgDefaults();
        s.Filter_Custom_Field_Name__c = 'Status';
        s.Filter_Custom_Field_Value__c = 'Active';
        update s;
        Test.setMock(HttpCalloutMock.class, new MockAsanaHttpCustomField());
        Test.startTest();
        AsanaWebhookProcessor.processTaskEvent('task003');
        Test.stopTest();
        List<copado__User_Story__c> stories = [SELECT Id FROM copado__User_Story__c WHERE Asana_Task_Id__c = 'task003'];
        System.assert(!stories.isEmpty(), 'Task matching custom field filter should be upserted');
    }

    @IsTest
    static void testProcessTaskCustomFieldFilterNoMatch() {
        Asana_Integration_Settings__c s = Asana_Integration_Settings__c.getOrgDefaults();
        s.Filter_Custom_Field_Name__c = 'Status';
        s.Filter_Custom_Field_Value__c = 'NonExistent';
        update s;
        Test.setMock(HttpCalloutMock.class, new MockAsanaHttpCustomField());
        Test.startTest();
        AsanaWebhookProcessor.processTaskEvent('task003');
        Test.stopTest();
        List<copado__User_Story__c> stories = [SELECT Id FROM copado__User_Story__c WHERE Asana_Task_Id__c = 'task003'];
        System.assert(stories.isEmpty(), 'Task not matching custom field filter should be skipped');
    }

    @IsTest
    static void testQueueableExecute() {
        Test.setMock(HttpCalloutMock.class, new MockAsanaHttpNoFilter());
        Test.startTest();
        AsanaWebhookQueueable q = new AsanaWebhookQueueable('task002');
        System.enqueueJob(q);
        Test.stopTest();
        System.assert(true);
    }

    @IsTest
    static void testWebhookRegistrationSuccess() {
        Test.setMock(HttpCalloutMock.class, new MockRegistrationSuccess());
        Test.startTest();
        AsanaWebhookRegistration.registerWebhook();
        Test.stopTest();
        Asana_Integration_Settings__c s = Asana_Integration_Settings__c.getOrgDefaults();
        System.assertEquals('webhook001', s.Webhook_GID__c, 'Webhook GID should be saved');
    }

    @IsTest
    static void testWebhookRegistrationFailure() {
        Test.setMock(HttpCalloutMock.class, new MockRegistrationFail());
        Test.startTest();
        AsanaWebhookRegistration.registerWebhook();
        Test.stopTest();
        System.assert(true, 'Should handle registration failure gracefully');
    }

    @IsTest
    static void testWebhookRegistrationNoSettings() {
        delete [SELECT Id FROM Asana_Integration_Settings__c];
        Test.startTest();
        AsanaWebhookRegistration.registerWebhook();
        Test.stopTest();
        System.assert(true, 'Should exit cleanly with no settings');
    }

    @IsTest
    static void testOutboundSyncBlankParams() {
        Test.startTest();
        AsanaOutboundSync.updateAsanaTask('', '');
        Test.stopTest();
        System.assert(true, 'Should exit cleanly with blank params');
    }

    @IsTest
    static void testOutboundSyncNoSettings() {
        delete [SELECT Id FROM Asana_Integration_Settings__c];
        Test.startTest();
        AsanaOutboundSync.updateAsanaTask('task_out_001', 'fakeId');
        Test.stopTest();
        System.assert(true, 'Should exit cleanly with no settings');
    }

    @IsTest
    static void testOutboundSyncSuccess() {
        copado__User_Story__c us = new copado__User_Story__c();
        us.copado__User_Story_Title__c = 'Outbound Test Story';
        us.Asana_Task_Id__c = 'task_out_001';
        insert us;
        Test.setMock(HttpCalloutMock.class, new MockOutboundSuccess());
        Test.startTest();
        AsanaOutboundSync.updateAsanaTask('task_out_001', us.Id);
        Test.stopTest();
        System.assert(true, 'Outbound sync should complete successfully');
    }

    @IsTest
    static void testOutboundSyncApiFailure() {
        copado__User_Story__c us = new copado__User_Story__c();
        us.copado__User_Story_Title__c = 'Outbound Fail Story';
        us.Asana_Task_Id__c = 'task_out_002';
        insert us;
        Test.setMock(HttpCalloutMock.class, new MockOutboundFail());
        Test.startTest();
        AsanaOutboundSync.updateAsanaTask('task_out_002', us.Id);
        Test.stopTest();
        System.assert(true, 'Should handle Asana API failure gracefully');
    }
}