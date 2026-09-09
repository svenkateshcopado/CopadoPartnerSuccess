@IsTest
private class AsanaTaskSyncTest {

    // ── Mock: list of tasks with tag and custom fields ────────────────────────────
    private class MockTaskListFull implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');
            res.setStatusCode(200);
            res.setBody('{"data":[{"gid":"11111","name":"Task One","resource_subtype":"default_task","notes":"desc","due_on":null,"assignee":null,"tags":[{"gid":"t1","name":"urgent"}],"custom_fields":[{"name":"Priority","display_value":"High"}],"memberships":[{"section":{"gid":"s1","name":"In Progress"}}]}]}');
            return res;
        }
    }

    private class MockEmpty implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');
            res.setStatusCode(200);
            res.setBody('{"data":[]}');
            return res;
        }
    }

    private class MockError implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(403);
            res.setBody('{"errors":[{"message":"Forbidden"}]}');
            return res;
        }
    }

    @TestSetup
    static void setup() {
        Asana_Integration_Settings__c s = new Asana_Integration_Settings__c(
            SetupOwnerId         = UserInfo.getOrganizationId(),
            Asana_Project_GID__c = '999888777'
        );
        insert s;

        Asana_Field_Mapping__c m = new Asana_Field_Mapping__c(
            Asana_Field__c  = 'name',
            Copado_Field__c = 'copado__User_Story_Title__c',
            Is_Active__c    = true
        );
        insert m;
    }

    @IsTest
    static void testSyncFullTask() {
        Test.setMock(HttpCalloutMock.class, new MockTaskListFull());
        Test.startTest();
        AsanaTaskSync.doSync();
        Test.stopTest();

        List<copado__User_Story__c> stories = [SELECT copado__User_Story_Title__c, Asana_Task_GID__c, Asana_Tags__c FROM copado__User_Story__c];
        System.assertEquals(1, stories.size(), 'Expected 1 user story to be upserted');
        System.assertEquals('Task One', stories[0].copado__User_Story_Title__c);
        System.assertEquals('11111',    stories[0].Asana_Task_GID__c);
    }

    @IsTest
    static void testSyncEmptyTaskList() {
        Test.setMock(HttpCalloutMock.class, new MockEmpty());
        Test.startTest();
        AsanaTaskSync.doSync();
        Test.stopTest();

        System.assertEquals(0, [SELECT Id FROM copado__User_Story__c].size());
    }

    @IsTest
    static void testSyncNonSuccessResponse() {
        Test.setMock(HttpCalloutMock.class, new MockError());
        Test.startTest();
        AsanaTaskSync.doSync();
        Test.stopTest();

        System.assertEquals(0, [SELECT Id FROM copado__User_Story__c].size());
    }

    @IsTest
    static void testSyncNoSettings() {
        delete [SELECT Id FROM Asana_Integration_Settings__c];
        Test.startTest();
        AsanaTaskSync.doSync();
        Test.stopTest();
        System.assertEquals(0, [SELECT Id FROM copado__User_Story__c].size());
    }

    @IsTest
    static void testSyncTasksInvocable() {
        Test.setMock(HttpCalloutMock.class, new MockEmpty());
        Test.startTest();
        AsanaTaskSync.syncTasks(new List<String>{ 'run' });
        Test.stopTest();
        System.assert(true, 'Invocable entry point executed without exception');
    }
}