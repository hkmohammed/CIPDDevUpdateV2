public WITHOUT SHARING class SynergyContactService {

    public static void handleContactUpdates(List<Contact> newList, Map<Id, Contact> oldMap) {
        System.debug('>>> SynergyContactService: Starting handleContactUpdates');
        Synergy_Settings__c settings = Synergy_Settings__c.getOrgDefaults();
        Id semarchyUserId = (settings.Semarchy_User_Id__c != null) ? (Id)settings.Semarchy_User_Id__c : null;
        
        for (Contact newCon : newList) {
            // GATING: Skip if the update came from the Semarchy Integration User
            if (semarchyUserId != null && newCon.LastModifiedById == semarchyUserId) {
                System.debug('>>> SynergyContactService: Update ignored. Change originated from Semarchy.');
                continue; 
            }

            Contact oldCon = oldMap.get(newCon.Id);
            
            // Significant Change Check: Verify if actual data changed before building the payload
            if (hasSignificantChanges(newCon, oldCon)) {
                
                // Build the FULL payload using ONLY the new contact state
                Map<String, Object> payload = buildFullPayload(newCon);
                
                // IMPORTANT: 'true' ensures NULL values are included to match the sample structure
                String jsonBody = JSON.serialize(payload, true);
                System.debug('>>> SynergyContactService: Significant changes detected. Payload size: ' + jsonBody.length());
                sendUpdateToSynergy(jsonBody);
            } else {
                System.debug('>>> SynergyContactService: No significant changes found for Contact ID: ' + newCon.Id);
            }
        }
    }

    private static Map<String, Object> buildFullPayload(Contact newCon) {
        Map<String, Object> payload = new Map<String, Object>();
        
        // 1. PRIMARY EMAIL LOGIC: Priority to Work Email, then standard Email
        String workEmailVal = (String)newCon.get('CTC_Work_Email__c');
        String primaryEmail = String.isNotBlank(workEmailVal) ? workEmailVal : newCon.Email;
        
        // 2. REQUIRED IDENTIFIERS
        payload.put('sourceSystem', 'Salesforce');
        payload.put('emailAddress', primaryEmail); 
        
        // External ID field mapping
        String contactNo = (String)newCon.get('CTC_Contact_Number__c');
        payload.put('contactNumber', String.isBlank(contactNo) ? '' : contactNo);

        // 3. PROFILE FIELDS: Always send the current value
        payload.put('title', newCon.Salutation);
        payload.put('firstName', newCon.FirstName);
        payload.put('lastName', newCon.LastName);
        

        //Version 2 for Contact Update : https://app.asana.com/1/10038461291784/project/1213214258823947/task/1213755118024617
        //24 March 2026
        payload.put('jobTitle', newCon.Title);
        payload.put('preferredName', newCon.get('CTC_Preferred_name__c'));
        payload.put('gender', newCon.get('CTC_Gender__c'));
        payload.put('dob', newCon.Birthdate != null ? String.valueOf(newCon.Birthdate) : null);
        // 4. ADDRESS OBJECTS: Forced full structure
        String prefAddr = (String)newCon.get('CTC_Default_Address__c');
        payload.put('homeAddress', mapFullAddress(newCon, 'Other', (prefAddr == 'Home Address'), 'ResidentialAddress.IsPreferred'));
        payload.put('workAddress', mapFullAddress(newCon, 'Mailing', (prefAddr == 'Work Address'), 'MailingAddress.IsPreferred'));

        // 5. SECONDARY EMAILS & PREFERENCES
        String prefDevice = (String)newCon.get('CTC_Preferred_Device__c');
        payload.put('homeEmail', newCon.get('CTC_Home_Email__c'));
        payload.put('workEmail', newCon.get('CTC_Work_Email__c'));
        
        // Booleans: Must be true/false, never null
        payload.put('PersonalEmail_IsPreferred', (prefDevice == 'Home Email'));
        payload.put('OfficialEmail_IsPreferred', (prefDevice == 'Work Email'));

        // 6. ROLE MAPPING: Mandatory Array with 'CIPDGuests' fallback
        String websiteRole = (String)newCon.get('Website_Role__c');
        payload.put('role', new List<String>{ String.isBlank(websiteRole) ? 'CIPDGuests' : websiteRole });

        return payload;
    }

    private static Map<String, Object> mapFullAddress(Contact con, String prefix, Boolean isPreferred, String prefKey) {
        // Determine which Salesforce fields to use based on the address prefix
        // Mailing = Work Address | Other = Home Address
        String landlineField = (prefix == 'Mailing') ? 'Phone' : 'HomePhone';
        String mobileField = 'MobilePhone'; // Usually same for both, or customize if needed

        // Always return the full current address state
        return new Map<String, Object>{
            'country' => con.get(prefix + 'Country'),
            'postCode' => con.get(prefix + 'PostalCode'),
            'addressLine1' => con.get(prefix + 'Street'),
            'addressLine2' => '', 
            'town' => con.get(prefix + 'City'),
            'county' => con.get(prefix + 'State'),
            'homeLandline' => (String)con.get(landlineField),
            'mobileNumber' => (String)con.get(mobileField),
            prefKey => (isPreferred == true)
        };
    }

    private static Boolean hasSignificantChanges(Contact newCon, Contact oldCon) {
        // List of all Salesforce fields mapped to the Semarchy payload
        Set<String> fieldsToCheck = new Set<String>{
            'Salutation', 'FirstName', 'LastName', 'CTC_Preferred_name__c',
            'Email', 'CTC_Work_Email__c', 'CTC_Home_Email__c', 'CTC_Contact_Number__c',
            'CTC_Default_Address__c', 'CTC_Preferred_Device__c', 'Website_Role__c',
            'Phone', 'HomePhone', 'MobilePhone',
            // Mailing Address fields
            'MailingStreet', 'MailingCity', 'MailingState', 'MailingPostalCode', 'MailingCountry',
            // Other Address fields
            'OtherStreet', 'OtherCity', 'OtherState', 'OtherPostalCode', 'OtherCountry'
        };

        // If any of these specific fields changed, we trigger the full payload update
        for (String field : fieldsToCheck) {
            if (newCon.get(field) != oldCon.get(field)) {
                return true;
            }
        }
        return false;
    }

    @future(callout=true)
    public static void sendUpdateToSynergy(String jsonPayload) {
        Synergy_Settings__c settings = Synergy_Settings__c.getOrgDefaults();
        Logic_App__c auth = Logic_App__c.getOrgDefaults();
        
        Http http = new Http();
        HttpRequest request = new HttpRequest();
        request.setEndpoint(settings.Base_URL__c + settings.Contact_Update_Endpoint__c);
        request.setMethod('POST');
        request.setHeader('Content-Type', 'application/json');
        request.setHeader('Ocp-Apim-Subscription-Key', auth.Ocp_Apim_Subscription_Key__c);
        request.setBody(jsonPayload);
        request.setTimeout(120000);

        try {
            HttpResponse response = http.send(request);
            logSemarchyResponse(response.getBody());
            
            if (settings.Enable_Debug_Email__c) {
                sendFormattedDebugEmail(settings.Debug_Email_Recipient__c, request.getEndpoint(), jsonPayload, response.getStatusCode(), response.getBody());
            }
        } catch(Exception e) {
            System.debug('>>> CALLOUT ERROR: ' + e.getMessage());
        }
    }

    private static void logSemarchyResponse(String body) {
        if (String.isBlank(body)) return;
        try {
            Object responseObj = JSON.deserializeUntyped(body);
            String prettyBody = JSON.serializePretty(responseObj);
            List<String> lines = prettyBody.split('\n');
            for (String line : lines) {
                System.debug('>>> SEMARCHY | ' + line);
            }
        } catch (Exception e) {
            System.debug('>>> SEMARCHY RAW: ' + body);
        }
    }

    private static void sendFormattedDebugEmail(String recipient, String endpoint, String sent, Integer code, String resp) {
        try {
            OrgWideEmailAddress owea = [SELECT Id FROM OrgWideEmailAddress WHERE Address = 'cipd@cipd.co.uk' LIMIT 1];
            Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
            mail.setOrgWideEmailAddressId(owea.Id);
            mail.setToAddresses(new String[] { recipient });
            mail.setSubject('Synergy Sync result: ' + code + ' ' + System.now().format());
            
            // Pretty print for the email debug
            String formattedSent = JSON.serializePretty(JSON.deserializeUntyped(sent));
            
            mail.setHtmlBody('<b>Full Payload Sent:</b><pre>' + formattedSent + '</pre><br/><b>Response:</b><pre>' + resp + '</pre>');
            Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ mail });
        } catch (Exception e) {
            System.debug('Email Error: ' + e.getMessage());
        }
    }
}