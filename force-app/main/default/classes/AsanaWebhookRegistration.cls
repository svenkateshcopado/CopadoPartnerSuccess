public class AsanaWebhookRegistration {

    public static void registerWebhook() {
        Asana_Integration_Settings__c settings = Asana_Integration_Settings__c.getOrgDefaults();

        // HIGH-01 FIX: Guard block no longer reads Asana_PAT__c.
        // Only Asana_Project_GID__c is required; Named Credential handles authentication.
        if (settings == null || String.isBlank(settings.Asana_Project_GID__c)) {
            System.debug('AsanaWebhookRegistration: Settings not configured. Asana_Project_GID__c is required.');
            return;
        }

        String projectGID = settings.Asana_Project_GID__c;
        String targetUrl  = 'https://copadopartnersuccess.my.salesforce-sites.com/AsanaIntegration/services/apexrest/asana/webhook';

        Map<String, Object> dataMap = new Map<String, Object>{
            'resource' => projectGID,
            'target'   => targetUrl,
            'filters'  => new List<Object>{
                new Map<String, Object>{ 'resource_type' => 'task', 'action' => 'added' },
                new Map<String, Object>{ 'resource_type' => 'task', 'action' => 'changed' }
            }
        };

        Map<String, Object> body = new Map<String, Object>{ 'data' => dataMap };

        // HIGH-01 FIX: Authorization header removed.
        // Named Credential 'AsanaCopado' injects the Bearer token automatically.
        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:AsanaCopado/api/1.0/webhooks');
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('Accept', 'application/json');
        req.setBody(JSON.serialize(body));
        req.setTimeout(120000);

        Http http = new Http();
        HttpResponse res = http.send(req);

        if (res.getStatusCode() == 201 || res.getStatusCode() == 200) {
            Map<String, Object> respMap = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            Map<String, Object> data    = (Map<String, Object>) respMap.get('data');
            String webhookGid = data != null ? String.valueOf(data.get('gid')) : '';
            settings.Webhook_GID__c = webhookGid;
            update settings;
            System.debug('AsanaWebhookRegistration: SUCCESS. Webhook GID = ' + webhookGid);
        } else {
            System.debug('AsanaWebhookRegistration: FAILED - ' + res.getStatusCode() + ' ' + res.getBody());
        }
    }
}