public class AsanaWebhookRegistration {

    public static void registerWebhook() {
        Asana_Integration_Settings__c settings = Asana_Integration_Settings__c.getOrgDefaults();
        if (settings == null || String.isBlank(settings.Asana_PAT__c) || String.isBlank(settings.Asana_Project_GID__c)) {
            System.debug('AsanaWebhookRegistration: Settings not configured.');
            return;
        }

        String projectGID = settings.Asana_Project_GID__c;
        String targetUrl  = 'https://copadopartnersuccess.my.salesforce-sites.com/AsanaIntegration/services/apexrest/asana/webhook';

        Map<String, Object> dataMap = new Map<String, Object>();
        dataMap.put('resource', projectGID);
        dataMap.put('target', targetUrl);
        dataMap.put('filters', new List<Map<String, Object>>{
            new Map<String, Object>{ 'resource_type' => 'task', 'action' => 'added' },
            new Map<String, Object>{ 'resource_type' => 'task', 'action' => 'changed' }
        });

        Map<String, Object> payload = new Map<String, Object>{ 'data' => dataMap };

        // HIGH-01 FIX: Authorization header removed. Named Credential handles auth.
        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:AsanaCopado/api/1.0/webhooks');
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setBody(JSON.serialize(payload));

        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() == 201) {
            Map<String, Object> respBody = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            Map<String, Object> respData = (Map<String, Object>) respBody.get('data');
            String webhookGid    = (String) respData.get('gid');
            String webhookSecret = res.getHeader('X-Hook-Secret');

            Asana_Integration_Settings__c upd = Asana_Integration_Settings__c.getOrgDefaults();
            if (upd == null) { upd = new Asana_Integration_Settings__c(); }
            upd.Webhook_GID__c    = webhookGid;
            upd.Webhook_Secret__c = webhookSecret;
            upsert upd;

            System.debug('AsanaWebhookRegistration: Webhook registered. GID=' + webhookGid);
        } else {
            System.debug('AsanaWebhookRegistration: Registration failed. Status=' + res.getStatusCode() + ' Body=' + res.getBody());
        }
    }
}
