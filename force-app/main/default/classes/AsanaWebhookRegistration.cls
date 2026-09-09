/**
 * AsanaWebhookRegistration
 *
 * Security fixes applied:
 *   MC-01  Webhook target URL read from Custom Setting (Webhook_Target_Url__c) at runtime.
 *          Falls back to a blank-check guard that prevents silent misconfiguration.
 *   LC-01  HTTP timeout reduced from 120 s to 30 s.
 *   LC-02  No sensitive data logged; only status codes and non-sensitive identifiers.
 */
public class AsanaWebhookRegistration {

    public static void registerWebhook() {
        Asana_Integration_Settings__c settings = Asana_Integration_Settings__c.getOrgDefaults();

        // HC-03 (already fixed): Guard checks Project GID, not PAT.
        if (settings == null || String.isBlank(settings.Asana_Project_GID__c)) {
            System.debug(LoggingLevel.ERROR,
                'AsanaWebhookRegistration: Asana_Project_GID__c is required but not configured.');
            return;
        }

        // MC-01: Read target URL from Custom Setting at runtime.
        // Store the full public site URL in Asana_Integration_Settings__c.Webhook_Target_Url__c.
        // Example value: https://copadopartnersuccess.my.salesforce-sites.com/AsanaIntegration/services/apexrest/asana/webhook
        String targetUrl = settings.Webhook_Target_Url__c;
        if (String.isBlank(targetUrl)) {
            System.debug(LoggingLevel.ERROR,
                'AsanaWebhookRegistration: Webhook_Target_Url__c is not configured in Asana_Integration_Settings__c.');
            return;
        }

        String projectGID = settings.Asana_Project_GID__c;

        Map<String, Object> dataMap = new Map<String, Object>{
            'resource' => projectGID,
            'target'   => targetUrl,
            'filters'  => new List<Object>{
                new Map<String, Object>{ 'resource_type' => 'task', 'action' => 'added' },
                new Map<String, Object>{ 'resource_type' => 'task', 'action' => 'changed' }
            }
        };

        Map<String, Object> body = new Map<String, Object>{ 'data' => dataMap };

        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:AsanaCopado/api/1.0/webhooks');
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('Accept', 'application/json');
        req.setBody(JSON.serialize(body));
        req.setTimeout(30000); // LC-01: Reduced from 120 s to 30 s.

        Http http = new Http();
        HttpResponse res = http.send(req);

        if (res.getStatusCode() == 201 || res.getStatusCode() == 200) {
            Map<String, Object> respMap = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            Map<String, Object> data    = (Map<String, Object>) respMap.get('data');
            String webhookGid = data != null ? String.valueOf(data.get('gid')) : '';
            settings.Webhook_GID__c = webhookGid;
            update settings;
            // LC-02: Log only the GID (non-sensitive identifier), not the full response body.
            System.debug(LoggingLevel.INFO, 'AsanaWebhookRegistration: SUCCESS. Webhook GID stored.');
        } else {
            // LC-02: Log only status code, not the full error body.
            System.debug(LoggingLevel.ERROR,
                'AsanaWebhookRegistration: Registration failed. HTTP ' + res.getStatusCode());
        }
    }
}
