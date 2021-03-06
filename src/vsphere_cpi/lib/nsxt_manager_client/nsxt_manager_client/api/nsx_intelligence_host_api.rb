=begin
#NSX-T Manager API

#VMware NSX-T Manager REST API

OpenAPI spec version: 2.5.1.0.0

Generated by: https://github.com/swagger-api/swagger-codegen.git
Swagger Codegen version: 2.4.7

=end

require 'uri'

module NSXT
  class NsxIntelligenceHostApi
    attr_accessor :api_client

    def initialize(api_client = ApiClient.default)
      @api_client = api_client
    end
    # Get NSX-Intelligence host configuration
    # Get the current NSX-Intelligence host configuration. 
    # @param [Hash] opts the optional parameters
    # @return [IntelligenceHostConfigurationInfo]
    def get_pace_host_configuration(opts = {})
      data, _status_code, _headers = get_pace_host_configuration_with_http_info(opts)
      data
    end

    # Get NSX-Intelligence host configuration
    # Get the current NSX-Intelligence host configuration. 
    # @param [Hash] opts the optional parameters
    # @return [Array<(IntelligenceHostConfigurationInfo, Fixnum, Hash)>] IntelligenceHostConfigurationInfo data, response status code and response headers
    def get_pace_host_configuration_with_http_info(opts = {})
      if @api_client.config.debugging
        @api_client.config.logger.debug 'Calling API: NsxIntelligenceHostApi.get_pace_host_configuration ...'
      end
      # resource path
      local_var_path = '/intelligence/host-config'

      # query parameters
      query_params = {}

      # header parameters
      header_params = {}
      # HTTP header 'Accept' (if needed)
      header_params['Accept'] = @api_client.select_header_accept(['application/json'])
      # HTTP header 'Content-Type'
      header_params['Content-Type'] = @api_client.select_header_content_type(['application/json'])

      # form parameters
      form_params = {}

      # http body (model)
      post_body = nil
      auth_names = ['BasicAuth']
      data, status_code, headers = @api_client.call_api(:GET, local_var_path,
        :header_params => header_params,
        :query_params => query_params,
        :form_params => form_params,
        :body => post_body,
        :auth_names => auth_names,
        :return_type => 'IntelligenceHostConfigurationInfo')
      if @api_client.config.debugging
        @api_client.config.logger.debug "API called: NsxIntelligenceHostApi#get_pace_host_configuration\nData: #{data.inspect}\nStatus code: #{status_code}\nHeaders: #{headers}"
      end
      return data, status_code, headers
    end
    # Patch NSX-Intelligence host configuration
    # Patch the current NSX-Intelligence host configuration. Return error if NSX-Intelligence is not registered with NSX. 
    # @param intelligence_host_configuration_info 
    # @param [Hash] opts the optional parameters
    # @return [IntelligenceHostConfigurationInfo]
    def patch_pace_host_configuration(intelligence_host_configuration_info, opts = {})
      data, _status_code, _headers = patch_pace_host_configuration_with_http_info(intelligence_host_configuration_info, opts)
      data
    end

    # Patch NSX-Intelligence host configuration
    # Patch the current NSX-Intelligence host configuration. Return error if NSX-Intelligence is not registered with NSX. 
    # @param intelligence_host_configuration_info 
    # @param [Hash] opts the optional parameters
    # @return [Array<(IntelligenceHostConfigurationInfo, Fixnum, Hash)>] IntelligenceHostConfigurationInfo data, response status code and response headers
    def patch_pace_host_configuration_with_http_info(intelligence_host_configuration_info, opts = {})
      if @api_client.config.debugging
        @api_client.config.logger.debug 'Calling API: NsxIntelligenceHostApi.patch_pace_host_configuration ...'
      end
      # verify the required parameter 'intelligence_host_configuration_info' is set
      if @api_client.config.client_side_validation && intelligence_host_configuration_info.nil?
        fail ArgumentError, "Missing the required parameter 'intelligence_host_configuration_info' when calling NsxIntelligenceHostApi.patch_pace_host_configuration"
      end
      # resource path
      local_var_path = '/intelligence/host-config'

      # query parameters
      query_params = {}

      # header parameters
      header_params = {}
      # HTTP header 'Accept' (if needed)
      header_params['Accept'] = @api_client.select_header_accept(['application/json'])
      # HTTP header 'Content-Type'
      header_params['Content-Type'] = @api_client.select_header_content_type(['application/json'])

      # form parameters
      form_params = {}

      # http body (model)
      post_body = @api_client.object_to_http_body(intelligence_host_configuration_info)
      auth_names = ['BasicAuth']
      data, status_code, headers = @api_client.call_api(:PATCH, local_var_path,
        :header_params => header_params,
        :query_params => query_params,
        :form_params => form_params,
        :body => post_body,
        :auth_names => auth_names,
        :return_type => 'IntelligenceHostConfigurationInfo')
      if @api_client.config.debugging
        @api_client.config.logger.debug "API called: NsxIntelligenceHostApi#patch_pace_host_configuration\nData: #{data.inspect}\nStatus code: #{status_code}\nHeaders: #{headers}"
      end
      return data, status_code, headers
    end
    # Reset NSX-Intelligence host configuration
    # Reset NSX-Intelligence host configuration to the default setting. Clear NSX-Intelligence host configuration if NSX-Intelligence is not registered with NSX. Return the NSX-Intelligence host configuration after reset operation. 
    # @param [Hash] opts the optional parameters
    # @return [IntelligenceHostConfigurationInfo]
    def reset_pace_host_configuration_reset(opts = {})
      data, _status_code, _headers = reset_pace_host_configuration_reset_with_http_info(opts)
      data
    end

    # Reset NSX-Intelligence host configuration
    # Reset NSX-Intelligence host configuration to the default setting. Clear NSX-Intelligence host configuration if NSX-Intelligence is not registered with NSX. Return the NSX-Intelligence host configuration after reset operation. 
    # @param [Hash] opts the optional parameters
    # @return [Array<(IntelligenceHostConfigurationInfo, Fixnum, Hash)>] IntelligenceHostConfigurationInfo data, response status code and response headers
    def reset_pace_host_configuration_reset_with_http_info(opts = {})
      if @api_client.config.debugging
        @api_client.config.logger.debug 'Calling API: NsxIntelligenceHostApi.reset_pace_host_configuration_reset ...'
      end
      # resource path
      local_var_path = '/intelligence/host-config?action=reset'

      # query parameters
      query_params = {}

      # header parameters
      header_params = {}
      # HTTP header 'Accept' (if needed)
      header_params['Accept'] = @api_client.select_header_accept(['application/json'])
      # HTTP header 'Content-Type'
      header_params['Content-Type'] = @api_client.select_header_content_type(['application/json'])

      # form parameters
      form_params = {}

      # http body (model)
      post_body = nil
      auth_names = ['BasicAuth']
      data, status_code, headers = @api_client.call_api(:POST, local_var_path,
        :header_params => header_params,
        :query_params => query_params,
        :form_params => form_params,
        :body => post_body,
        :auth_names => auth_names,
        :return_type => 'IntelligenceHostConfigurationInfo')
      if @api_client.config.debugging
        @api_client.config.logger.debug "API called: NsxIntelligenceHostApi#reset_pace_host_configuration_reset\nData: #{data.inspect}\nStatus code: #{status_code}\nHeaders: #{headers}"
      end
      return data, status_code, headers
    end
  end
end
