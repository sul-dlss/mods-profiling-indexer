require 'spec_helper'

RSpec.describe Indexer do

  before(:all) do
    @config_yml_path = File.join(File.dirname(__FILE__), "..", "config", "feigenbaum.yml")
    require 'yaml'
    @yaml = YAML.load_file(@config_yml_path)
    @ns_decl = "xmlns='#{Mods::MODS_NS}'"
    @fake_druid = 'oo000oo0000'
    @fake_coll_druid = 'oo666oo6666'
    mods_xml = "<mods #{@ns_decl}><note>Indexer test</note></mods>"
    @ng_mods_xml =  Nokogiri::XML(mods_xml)
    pub_xml = "<publicObject id='druid#{@fake_druid}'></publicObject>"
    @ng_pub_xml = Nokogiri::XML(pub_xml)
  end
  before(:each) do
    @indexer = Indexer.new(@config_yml_path) do |config|
      config.whitelist = ["druid:ms016pb9280"]
    end
    allow(@indexer.solr_client).to receive(:add)
  end

  let :resource do
    r = Harvestdor::Indexer::Resource.new(double, @fake_druid)
    allow(r).to receive(:collections).and_return []
    allow(r).to receive(:mods).and_return @ng_mods_xml
    allow(r).to receive(:public_xml).and_return @ng_pub_xml
    allow(r).to receive(:public_xml?).and_return true
    allow(r).to receive(:content_metadata).and_return nil
    allow(r).to receive(:collection?).and_return false
    r
  end

  let :collection do
    r = Harvestdor::Indexer::Resource.new(double, @fake_coll_druid)
    allow(r).to receive(:collections).and_return []
    allow(r).to receive(:mods).and_return @ng_mods_xml
    allow(r).to receive(:public_xml).and_return @ng_pub_xml
    allow(r).to receive(:public_xml?).and_return true
    allow(r).to receive(:content_metadata).and_return nil
    allow(r).to receive(:identity_md_obj_label).and_return ""
    allow(r).to receive(:collection?).and_return true
    r
  end

  context "logging" do
    it "should write the log file to the directory indicated by log_dir" do
      @indexer.logger.info("feigenbaum logging test message")
      expect(File).to exist(File.join(@yaml['harvestdor']['log_dir'], @yaml['harvestdor']['log_name']))
    end
    it 'logger level defaults to INFO' do
      expect(@indexer.logger.level).to eq (Logger::INFO)
    end
    it 'logger level can be specified in config field' do
      indexer = Indexer.new(@config_yml_path) do |config|
        config.log_level = 'debug'
      end
      expect(indexer.logger.level).to eq (Logger::DEBUG)
      indexer = Indexer.new(@config_yml_path) do |config|
        config.log_level = 'warn'
      end
      expect(indexer.logger.level).to eq (Logger::WARN)
    end
  end

  describe "#harvest_and_index" do
    before :each do
      allow(@indexer.harvestdor).to receive(:each_resource)
      allow(@indexer).to receive(:solr_client).and_return(double(commit!: nil))
      allow(@indexer).to receive(:log_results)
      allow(@indexer).to receive(:email_results)
    end
    it "should log and email results" do
      expect(@indexer).to receive(:log_results)
      expect(@indexer).to receive(:email_results)

      @indexer.harvest_and_index
    end
    it "should index each resource" do
      allow(@indexer).to receive(:harvestdor).and_return(Class.new do
        def initialize *items
          @items = items
        end
        def each_resource opts = {}
          @items.each { |x| yield x }
        end
        def logger
          Logger.new(STDERR)
        end
      end.new(collection, resource))

      expect(@indexer).to receive(:index).with(collection)
      expect(@indexer).to receive(:index).with(resource)

      @indexer.harvest_and_index
    end
    it "should send a solr commit" do
      expect(@indexer.solr_client).to receive(:commit!)
      @indexer.harvest_and_index
    end
    it "should not commit if nocommit is set" do
      expect(@indexer.solr_client).to_not receive(:commit!)
      @indexer.harvest_and_index(true)
    end
  end

  describe "#index" do
    it "should index other resources as items" do
      expect(@indexer).to receive(:solr_document).with(resource)
      @indexer.index resource
    end
  end

  describe "#index_with_exception_handling" do
    it "should capture, log, and re-raise any exception thrown by the indexing process" do
      expect(@indexer).to receive(:index).with(resource).and_raise "xyz"
      expect(@indexer.logger).to receive(:error)
      expect { @indexer.index_with_exception_handling(resource) }.to raise_error RuntimeError
      expect(@indexer.druids_failed_to_ix).to include resource.druid
    end
  end


  context "#solr_document" do

    before(:all) do
      @ns_decl = "xmlns='#{Mods::MODS_NS}'"
      @title = 'qervavdsaasdfa'
      @ng_mods = Nokogiri::XML("<mods #{@ns_decl}><titleInfo><title>#{@title}</title></titleInfo></mods>")
    end
    before(:each) do
      allow_any_instance_of(Harvestdor::Client).to receive(:mods).with(@fake_druid).and_return(@ng_mods)
    end

    it "has fields populated from the MODS" do
      doc_hash = @indexer.solr_document(resource)
      expect(doc_hash[:titleInfo_sim]).to eq [@title]
    end

    context "collection field" do
      it "populated from the yml if there is no overriding config value" do
        indexer = Indexer.new(@config_yml_path)
        doc_hash = indexer.solr_document(resource)
        expect(doc_hash[:collection]).to eq 'feigenbaum'
      end

      it "able to use options from the config" do
        indexer = Indexer.new(@config_yml_path, Confstruct::Configuration.new(:coll_fld_val => 'this_coll'))
        doc_hash = indexer.solr_document(resource)
        expect(doc_hash[:collection]).to eq 'this_coll'
      end
    end

  end # solr_doc


  context "#item_solr_document" do
    context "unmerged" do
      it "calls Harvestdor::Indexer.solr_add" do
        doc_hash = @indexer.item_solr_document(resource)
        expect(doc_hash).to include id: @fake_druid
      end
      it "calls validate_item" do
        expect_any_instance_of(GDor::Indexer::SolrDocHash).to receive(:validate_item).and_return([])
        @indexer.item_solr_document resource
      end
      it "calls GDor::Indexer::SolrDocBuilder.validate_mods" do
        allow_any_instance_of(GDor::Indexer::SolrDocHash).to receive(:validate_item).and_return([])
        expect_any_instance_of(GDor::Indexer::SolrDocHash).to receive(:validate_mods).and_return([])
        @indexer.item_solr_document resource
      end
      it "calls add_coll_info" do
        expect(@indexer).to receive(:add_coll_info)
        @indexer.item_solr_document resource
      end
      it "should have fields populated from the collection record" do
        sdb = double
        allow(sdb).to receive(:doc_hash).and_return(GDor::Indexer::SolrDocHash.new)
        allow(sdb).to receive(:display_type)
        allow(sdb).to receive(:file_ids)
        allow(sdb.doc_hash).to receive(:validate_mods).and_return([])
        allow(GDor::Indexer::SolrDocBuilder).to receive(:new).and_return(sdb)
        allow(resource).to receive(:collections).and_return([double(druid: "foo", bare_druid: "foo", identity_md_obj_label: "bar")])
        doc_hash = @indexer.item_solr_document resource
        expect(doc_hash).to include druid: @fake_druid, :collection => ['foo'], :collection_with_title => ['foo-|-bar']
      end
      it "should have fields populated from the MODS" do
        title = 'fake title in mods'
        ng_mods = Nokogiri::XML("<mods #{@ns_decl}><titleInfo><title>#{title}</title></titleInfo></mods>")
        allow(resource).to receive(:mods).and_return(ng_mods)
        doc_hash = @indexer.item_solr_document resource
        expect(doc_hash).to include id: @fake_druid, :title_display => title
      end
      it "should populate url_fulltext field with purl page url" do
        doc_hash = @indexer.item_solr_document resource
        expect(doc_hash).to include id: @fake_druid, :url_fulltext => "#{@yaml['harvestdor']['purl']}/#{@fake_druid}"
      end
      it "should populate druid and access_facet fields" do
        doc_hash = @indexer.item_solr_document resource
        expect(doc_hash).to include id: @fake_druid, :druid => @fake_druid, :access_facet => 'Online'
      end
      it "should populate display_type field by calling display_type method" do
        expect_any_instance_of(GDor::Indexer::SolrDocBuilder).to receive(:display_type).and_return("foo")
        doc_hash = @indexer.item_solr_document resource
        expect(doc_hash).to include id: @fake_druid, :display_type => "foo"
      end
      it "should populate file_id field by calling file_ids method" do
        expect_any_instance_of(GDor::Indexer::SolrDocBuilder).to receive(:file_ids).at_least(1).times.and_return(["foo"])
        doc_hash = @indexer.item_solr_document resource
        expect(doc_hash).to include id: @fake_druid, :file_id => ["foo"]
      end
      it "should populate building_facet field with Stanford Digital Repository" do
        doc_hash = @indexer.item_solr_document resource
        expect(doc_hash).to include id: @fake_druid, :building_facet => 'Stanford Digital Repository'
      end
    end # unmerged item

  end # item_solr_document

  context "#add_coll_info and supporting methods" do
    before(:each) do
      @coll_druids_array = [collection]
    end

    it "should add no collection field values to doc_hash if there are none" do
      doc_hash = GDor::Indexer::SolrDocHash.new({})
      @indexer.add_coll_info(doc_hash, nil)
      expect(doc_hash[:collection]).to be_nil
      expect(doc_hash[:collection_with_title]).to be_nil
      expect(doc_hash[:display_type]).to be_nil
    end

    context "collection field" do
      it "should be added field to doc hash" do
        doc_hash = GDor::Indexer::SolrDocHash.new({})
        @indexer.add_coll_info(doc_hash, @coll_druids_array)
        expect(doc_hash[:collection]).to match_array [@fake_coll_druid]
      end
      it "should add two values to doc_hash when object belongs to two collections" do
        coll_druid1 = 'oo111oo2222'
        coll_druid2 = 'oo333oo4444'
        doc_hash = GDor::Indexer::SolrDocHash.new({})
        @indexer.add_coll_info(doc_hash, [double(druid: coll_druid1, bare_druid: coll_druid1, public_xml: @ng_pub_xml, identity_md_obj_label: ""), double(druid: coll_druid2, bare_druid: coll_druid2, public_xml: @ng_pub_xml, identity_md_obj_label: "")])
        expect(doc_hash[:collection]).to match_array [coll_druid1, coll_druid2]
      end
    end

  end #add_coll_info

  context "#num_found_in_solr" do
    before :each do
      @unmerged_collection_response =
        {
          'response' =>
          { 'numFound' => '1',
            'docs' => [
              {
                'id' => 'dm212rn7381',
                'url_fulltext' => ['http://purl.stanford.edu/dm212rn7381']
              }
            ]
          }
        }
      @item_response =
        {
          'response' =>
          {
            'numFound' => '265',
            'docs' => [{ 'id' => 'dm212rn7381' }]
          }
        }
    end

    it 'should count the items in the solr index after indexing' do
      allow(@indexer.solr_client.client).to receive(:get) do |wt, params|
        if params[:params][:fq].include?('id:"dm212rn7381"')
          @unmerged_collection_response
        else
          @item_response
        end
      end
      expect(@indexer.num_found_in_solr(collection: "dm212rn7381")).to eq(266)
    end
  end # num_found_in_solr

  context "#email_report_body" do
    before :each do
      @indexer.config.notification = "notification-list@example.com"
      allow(@indexer).to receive(:num_found_in_solr).and_return(500)
      allow(@indexer.harvestdor).to receive(:resources).and_return([collection])
      allow(collection).to receive(:items).and_return([1,2,3])
      allow(collection).to receive(:identity_md_obj_label).and_return("testcoll title")
    end

    subject do
      @indexer.email_report_body
    end

    it "email body includes coll id" do
      expect(subject).to match /testcoll indexed coll record is: oo666oo6666/
    end

    it "email body includes coll title" do
     expect(subject).to match /coll title: testcoll title/
    end

    it "email body includes failed to index druids" do
      @indexer.instance_variable_set(:@druids_failed_to_ix, ['a', 'b'])
      expect(subject).to match /records that may have failed to index \(merged recs as druids, not ckeys\): \na\nb\n\n/
    end

    it "email body include validation messages" do
      @indexer.instance_variable_set(:@validation_messages, ['this is a validation message'])
      expect(subject).to match /this is a validation message/
    end

    it "email includes reference to full log" do
      expect(subject).to match /full log is at gdor_indexer\/shared\/spec\/logs\/testcoll\.log/
    end
  end

  describe "#email_results" do
    before :each do
      @indexer.config.notification = "notification-list@example.com"
      allow(@indexer).to receive(:send_email)
      allow(@indexer).to receive(:email_report_body).and_return("Report Body")
    end

    it "should have an appropriate subject" do
      expect(@indexer).to receive(:send_email) do |to, opts|
        expect(opts[:subject]).to match /is finished/
      end

      @indexer.email_results
    end

    it "should send the email to the notification list" do
      expect(@indexer).to receive(:send_email) do |to, opts|
        expect(to).to eq @indexer.config.notification
      end

      @indexer.email_results
    end

    it "should have the report body" do
      expect(@indexer).to receive(:send_email) do |to, opts|
        expect(opts[:body]).to eq "Report Body"
      end

      @indexer.email_results
    end
  end

  describe "#send_email" do
    it "should send an email to the right list" do
      expect_any_instance_of(Mail::Message).to receive(:deliver!) do |mail|
        expect(mail.to).to match_array ["notification-list@example.com"]
      end
      @indexer.send_email "notification-list@example.com", {}
    end

    it "should have the appropriate options set" do
      expect_any_instance_of(Mail::Message).to receive(:deliver!) do |mail|
        expect(mail.subject).to eq "Subject"
        expect(mail.from).to match_array ["rspec"]
        expect(mail.body).to eq "Body"
      end
      @indexer.send_email "notification-list@example.com", {from: "rspec", subject: "Subject", body: "Body"}
    end
  end

end
