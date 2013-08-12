# external gems
require 'confstruct'
require 'harvestdor'
require 'rsolr'
# stdlib
require 'logger'

# local files
require 'solr_doc_builder'

# Base class to harvest from DOR via harvestdor gem
class Indexer

  def initialize yml_path, options = {}
    @yml_path = yml_path
    config.configure(YAML.load_file(yml_path)) if yml_path    
    config.configure options 
    yield(config) if block_given?
  end
  
  def config
    @config ||= Confstruct::Configuration.new()
  end

  def logger
    @logger ||= load_logger(config.log_dir, config.log_name)
  end
  
  # per this Indexer's config options 
  #  harvest the druids via OAI
  #   create a Solr profiling document for each druid
  #   write the result to the Solr index
  def harvest_and_index
    if whitelist.empty?
      druids.each { |druid| index druid }
    else
      whitelist.each { |druid| index druid unless druid.start_with?("#") }
    end
    solr_client.commit
    logger.info("Finished processing: Solr commit returned.")
  end
  
  # return Array of druids contained in the OAI harvest indicated by OAI params in yml configuration file
  # @return [Array<String>] or enumeration over it, if block is given.  (strings are druids, e.g. ab123cd1234)
  def druids
    @druids ||= harvestdor_client.druids_via_oai
  end

  # Create a Solr doc, as a Hash, to be added to the SearchWorks Solr index.  
  # Solr doc contents are based on the mods, contentMetadata, etc. for the druid
  # @param [String] druid, e.g. ab123cd4567
  # @param [Stanford::Mods::Record] MODS metadata as a Stanford::Mods::Record object
  # @param [Hash] Hash representing the Solr document
  def solr_doc druid
    sdb = SolrDocBuilder.new(druid, harvestdor_client, logger)
    doc_hash = sdb.doc_hash
    doc_hash[:collection] = config.coll_fld_val ? config.coll_fld_val : config.default_set

    # add things from Indexer level class (info kept here for caching purposes)
    doc_hash
  end
    
  def solr_client
    @solr_client ||= RSolr.connect(config.solr.to_hash)
  end
  
  # @return an Array of druids ('oo000oo0000') that should NOT be processed
  def blacklist
    # avoid trying to load the file multiple times
    if !@blacklist && !@loaded_blacklist
      @blacklist = load_blacklist(config.blacklist) if config.blacklist
    end
    @blacklist ||= []
  end
  
  # @return an Array of druids ('oo000oo0000') that SHOULD be processed
  def whitelist
    # avoid trying to load the file multiple times
    if !@whitelist && !@loaded_whitelist
      @whitelist = load_whitelist(config.whitelist) if config.whitelist
    end
    @whitelist ||= []
  end
  
  protected #---------------------------------------------------------------------

  def harvestdor_client
    @harvestdor_client ||= Harvestdor::Client.new({:config_yml_path => @yml_path})
  end
  
  # create Solr doc for the druid and add it to Solr, unless it is on the blacklist.  
  #  NOTE: no Solr commit performed
  def index druid
    if blacklist.include?(druid)
      logger.info("Druid #{druid} is on the blacklist and will have no Solr doc created")
    else
      solr_client.add(solr_doc(druid))
      logger.info("Just created Solr doc for #{druid}")
      # TODO: update DOR object's workflow datastream??
    end
  end
  
  # Global, memoized, lazy initialized instance of a logger
  # @param String directory for to get log file
  # @param String name of log file
  def load_logger(log_dir, log_name)
    Dir.mkdir(log_dir) unless File.directory?(log_dir) 
    @logger ||= Logger.new(File.join(log_dir, log_name), 'daily')
  end
  
  # populate @blacklist as an Array of druids ('oo000oo0000') that will NOT be processed
  #  by reading the File at the indicated path
  # @param path - path of file containing a list of druids
  def load_blacklist path
    if path && !@loaded_blacklist
      @loaded_blacklist = true
      @blacklist = load_id_list path
    end
  end
    
  # populate @blacklist as an Array of druids ('oo000oo0000') that WILL be processed
  #  (unless a druid is also on the blacklist)
  #  by reading the File at the indicated path
  # @param path - path of file containing a list of druids
  def load_whitelist path
    if path && !@loaded_whitelist
      @loaded_whitelist = true
      @whitelist = load_id_list path
    end
  end
    
  # return an Array of druids ('oo000oo0000')
  #   populated by reading the File at the indicated path
  # @param path - path of file containing a list of druids
  # @return an Array of druids
  def load_id_list path
    if path 
      list = []
      f = File.open(path).each_line { |line|
        list << line.gsub(/\s+/, '') if !line.gsub(/\s+/, '').empty?
      }
      list
    end
  rescue
    msg = "Unable to find list of druids at " + path
    logger.fatal msg
    raise msg
  end
    
end
