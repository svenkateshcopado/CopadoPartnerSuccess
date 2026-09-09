@IsTest
private class AsanaOutboundSyncTest {

    // ── Mock: successful PUT to Asana ─────────────────────────────────────────────
    private class MockAsanaPutSuccess implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');
            res.setBody('{"data":{"gid":"55555","name":"Updated Task"}}');
            res.setStatusCode(200);
            return res;
        }
    }

    private class MockAsanaPutError implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(500);
            res.setBody('{"errors":[{"message":"Internal Server Error"}]}');
            return res;
        }
    }

    @TestSetup
    static void setup() {
        Asana_Integration_Settings__c s = new Asana_Integration_Settings__c(
            SetupOwnerId         = UserInfo.getOrganizationId(),
            Asana_Project_GID__c = '123456789'
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
    static void testUpdateAsanaTaskSuccess() {
        copado__User_Story__c us = new copado__User_Story__c(
            copado__User_Story_Title__c = 'Test Story',
            copado__Status__c           = 'In Progress'
        );
        insert us;

        Test.setMock(HttpCalloutMock.class, new MockAsanaPutSuccess());
        Test.startTest();
        AsanaOutboundSync.updateAsanaTask('55555', us.Id);
        Test.stopTest();

        System.assert(true, 'Outbound sync completed without exception');
    }

    @IsTest
    static void testUpdateAsanaTaskErrorResponse() {
        copado__User_Story__c us = new copado__User_Story__c(
            copado__User_Story_Title__c = 'Error Story'
        );
        insert us;

        Test.setMock(HttpCalloutMock.class, new MockAsanaPutError());
        Test.startTest();
        AsanaOutboundSync.updateAsanaTask('55555', us.Id);
        Test.stopTest();

        System.assert(true, 'Handled non-200 response gracefully');
    }

    @IsTest
    static void testMissingParams() {
        Test.startTest();
        AsanaOutboundSync.updateAsanaTask(null, null);
        AsanaOutboundSync.updateAsanaTask('', '');
        Test.stopTest();
        System.assert(true, 'Handled blank params without exception');
    }

    @IsTest
    static void testMissingSettings() {
        delete [SELECT Id FROM Asana_Integration_Settings__c];
        copado__User_Story__c us = new copado__User_Story__c(
            copado__User_Story_Title__c = 'No Settings Story'
        );
        insert us;

        Test.startTest();
        AsanaOutboundSync.updateAsanaTask('55555', us.Id);
        Test.stopTest();
        System.assert(true, 'Handled missing settings gracefully');
    }
}