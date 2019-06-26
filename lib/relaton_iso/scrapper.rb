# frozen_string_literal: true

require "algoliasearch"
require "relaton_iso_bib"
require "relaton_iso/hit"
require "nokogiri"
require "net/http"

Algolia.init application_id: "JCL49WV5AR",
             api_key: "dd1b9e1ab383f4d4817d29cd5e96d3f0"

module RelatonIso
  # Scrapper.
  # rubocop:disable Metrics/ModuleLength
  module Scrapper
    DOMAIN = "https://www.iso.org"

    TYPES = {
      "TS" => "technical-specification",
      "TR" => "technical-report",
      "PAS" => "publicly-available-specification",
      # "AWI" => "approvedWorkItem",
      # "CD" => "committeeDraft",
      # "FDIS" => "finalDraftInternationalStandard",
      # "NP" => "newProposal",
      # "DIS" => "draftInternationalStandard",
      # "WD" => "workingDraft",
      # "R" => "recommendation",
      "Guide" => "guide",
    }.freeze

    class << self
      # @param text [String]
      # @return [Array<Hash>]
      # def get(text)
      #   iso_workers = RelatonBib::WorkersPool.new 4
      #   iso_workers.worker { |hit| iso_worker(hit, iso_workers) }
      #   algolia_workers = start_algolia_search(text, iso_workers)
      #   iso_docs = iso_workers.result
      #   algolia_workers.end
      #   algolia_workers.result
      #   iso_docs
      # rescue
      #   warn "Could not connect to http://www.iso.org"
      #   []
      # end

      # Parse page.
      # @param hit [Hash]
      # @return [Hash]
      # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      def parse_page(hit_data)
        return unless hit_data["path"] =~ /\d+$/

        doc, url = get_page "/standard/#{hit_data['path'].match(/\d+$/)}.html"

        # Fetch edition.
        edition = doc&.xpath("//strong[contains(text(), 'Edition')]/..")&.
          children&.last&.text&.match(/\d+/)&.to_s

        titles, abstract = fetch_titles_abstract(doc)

        RelatonIsoBib::IsoBibliographicItem.new(
          fetched: Date.today.to_s,
          docid: fetch_docid(doc),
          edition: edition,
          language: langs(doc).map { |l| l[:lang] },
          script: langs(doc).map { |l| script(l[:lang]) }.uniq,
          titles: titles,
          type: fetch_type(hit_data["title"]),
          docstatus: fetch_status(doc, hit_data["status"]),
          ics: fetch_ics(doc),
          dates: fetch_dates(doc),
          contributors: fetch_contributors(hit_data["title"]),
          editorialgroup: fetch_workgroup(doc),
          abstract: abstract,
          copyright: fetch_copyright(hit_data["title"], doc),
          link: fetch_link(doc, url),
          relations: fetch_relations(doc),
          structuredidentifier: fetch_structuredidentifier(doc),
        )
      end
      # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

      private

      # Start algolia search workers.
      # @param text[String]
      # @param iso_workers [RelatonBib::WorkersPool]
      # @reaturn [RelatonBib::WorkersPool]
      # def start_algolia_search(text, iso_workers)
      #   index = Algolia::Index.new "all_en"
      #   algolia_workers = RelatonBib::WorkersPool.new
      #   algolia_workers.worker do |page|
      #     algolia_worker(index, text, page, algolia_workers, iso_workers)
      #   end

      #   # Add first page so algolia worker will start.
      #   algolia_workers << 0
      # end

      # Fetch ISO documents.
      # @param hit [Hash]
      # @param isiso_workers [RelatonIso::WorkersPool]
      # def iso_worker(hit, iso_workers)
      #   print "Parse #{iso_workers.size} of #{iso_workers.nb_hits}  \r"
      #   parse_page hit
      # end

      # Fetch hits from algolia search service.
      # @param index[Algolia::Index]
      # @param text [String]
      # @param page [Integer]
      # @param algolia_workers [RelatonBib::WorkersPool]
      # @param isiso_workers [RelatonBib::WorkersPool]
      # def algolia_worker(index, text, page, algolia_workers, iso_workers)
      #   res = index.search text, facetFilters: ["category:standard"], page: page
      #   next_page = res["page"] + 1
      #   algolia_workers << next_page if next_page < res["nbPages"]
      #   res["hits"].each do |hit|
      #     iso_workers.nb_hits = res["nbHits"]
      #     iso_workers << hit
      #   end
      #   iso_workers.end unless next_page < res["nbPages"]
      # end

      # Fetch titles and abstracts.
      # @param doc [Nokigiri::HTML::Document]
      # @return [Array<Array>]
      # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      def fetch_titles_abstract(doc)
        titles   = []
        abstract = []
        langs(doc).each do |lang|
          # Don't need to get page for en. We already have it.
          d = lang[:path] ? get_page(lang[:path])[0] : doc

          # Check if unavailable for the lang.
          next if d.css("h5.help-block").any?

          titles << fetch_title(d, lang[:lang])

          # Fetch abstracts.
          abstract_content = d.css("div[itemprop='description'] p").text
          next if abstract_content.empty?

          abstract << {
            content: abstract_content,
            language: lang[:lang],
            script: script(lang[:lang]),
            format: "text/plain",
          }
        end
        [titles, abstract]
      end
      # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

      # Get langs.
      # @param doc [Nokogiri::HTML::Document]
      # @return [Array<Hash>]
      def langs(doc)
        lgs = [{ lang: "en" }]
        doc.css("ul#lang-switcher ul li a").each do |lang_link|
          lang_path = lang_link.attr("href")
          lang = lang_path.match(%r{^\/(fr)\/})
          lgs << { lang: lang[1], path: lang_path } if lang
        end
        lgs
      end

      # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      # Get page.
      # @param path [String] page's path
      # @return [Array<Nokogiri::HTML::Document, String>]
      def get_page(path)
        url = DOMAIN + path
        uri = URI url
        resp = Net::HTTP.get_response(uri) # .encode("UTF-8")
        case resp.code
        when "301"
          path = resp["location"]
          url = DOMAIN + path
          uri = URI url
          resp = Net::HTTP.get_response(uri) # .encode("UTF-8")
        when "404"
          raise RelatonBib::RequestError, "#{url} not found."
        end
        n = 0
        while resp.body !~ /<strong/ && n < 10
          resp = Net::HTTP.get_response(uri) # .encode("UTF-8")
          n += 1
        end
        [Nokogiri::HTML(resp.body), url]
      rescue SocketError, Timeout::Error, Errno::EINVAL, Errno::ECONNRESET, EOFError,
             Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError, Net::ProtocolError
        raise RelatonBib::RequestError, "Could not access #{url}"
      end
      # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

      # Fetch docid.
      # @param doc [Nokogiri::HTML::Document]
      # @return [Array<RelatonBib::DocumentIdentifier>]
      def fetch_docid(doc)
        item_ref = doc.at("//strong[@id='itemReference']")
        return [] unless item_ref

        [RelatonBib::DocumentIdentifier.new(id: item_ref.text, type: "ISO")]
      end

      # @param doc [Nokogiri::HTML::Document]
      def fetch_structuredidentifier(doc)
        item_ref = doc.at("//strong[@id='itemReference']")
        unless item_ref
          return RelatonIsoBib::StructuredIdentifier.new(
            project_number: "?", part_number: "", prefix: nil, id: "?",
          )
        end

        m = item_ref.text.match(/^(.*?\d+)-?((?<=-)\d+|)/)
        RelatonIsoBib::StructuredIdentifier.new(
          project_number: m[1], part_number: m[2], prefix: nil,
          id: item_ref.text, type: "ISO"
        )
      end

      # Fetch status.
      # @param doc [Nokogiri::HTML::Document]
      # @param status [String]
      # @return [Hash]
      def fetch_status(doc, _status)
        stage, substage = doc.css("li.dropdown.active span.stage-code > strong").text.split "."
        RelatonBib::DocumentStatus.new(stage: stage, substage: substage)
      end

      # Fetch workgroup.
      # @param doc [Nokogiri::HTML::Document]
      # @return [Hash]
      def fetch_workgroup(doc)
        wg_link = doc.css("div.entry-name.entry-block a")[0]
        # wg_url = DOMAIN + wg_link['href']
        workgroup = wg_link.text.split "/"
        {
          name: "International Organization for Standardization",
          abbreviation: "ISO",
          url: "www.iso.org",
          technical_committee: [{
            name: wg_link.text + doc.css("div.entry-title")[0].text,
            type: "TC",
            number: workgroup[1]&.match(/\d+/)&.to_s&.to_i,
          }],
        }
      end

      # rubocop:disable Metrics/MethodLength

      # Fetch relations.
      # @param doc [Nokogiri::HTML::Document]
      # @return [Array<Hash>]
      def fetch_relations(doc)
        doc.css("ul.steps li").reduce([]) do |a, r|
          r_type = r.css("strong").text
          type = case r_type
                 when "Previously", "Will be replaced by" then "obsoletes"
                 when "Corrigenda/Amendments", "Revised by", "Now confirmed"
                   "updates"
                 else r_type
                 end
          if ["Now", "Now under review"].include? type
            a
          else
            a + r.css("a").map do |id|
              fref = RelatonBib::FormattedRef.new(
                content: id.text, format: "text/plain",
              )
              bibitem = RelatonIsoBib::IsoBibliographicItem.new(
                formattedref: fref,
              )
              { type: type, bibitem: bibitem }
            end
          end
        end
      end
      # rubocop:enable Metrics/MethodLength

      # Fetch type.
      # @param title [String]
      # @return [String]
      def fetch_type(title)
        type_match = title.match(%r{^(ISO|IWA|IEC)(?:(/IEC|/IEEE|/PRF|
          /NP)*\s|/)(TS|TR|PAS|AWI|CD|FDIS|NP|DIS|WD|R|Guide|(?=\d+))}x)
        # return "international-standard" if type_match.nil?
        if TYPES[type_match[3]]
          TYPES[type_match[3]]
        elsif type_match[1] == "ISO"
          "international-standard"
        elsif type_match[1] == "IWA"
          "international-workshop-agreement"
        end
        # rescue => _e
        #   puts 'Unknown document type: ' + title
      end

      # Fetch titles.
      # @param doc [Nokogiri::HTML::Document]
      # @param lang [String]
      # @return [Hash]
      def fetch_title(doc, lang)
        titles = doc.at("//h3[@itemprop='description'] | //h2[@itemprop='description']").
          text.split " -- "
        case titles.size
        when 0
          intro, main, part = nil, "", nil
        when 1
          intro, main, part = nil, titles[0], nil
        when 2
          if /^(Part|Partie) \d+:/ =~ titles[1]
            intro, main, part = nil, titles[0], titles[1]
          else
            intro, main, part = titles[0], titles[1], nil
          end
        when 3
          intro, main, part = titles[0], titles[1], titles[2]
        else
          intro, main, part = titles[0], titles[1], titles[2..-1]&.join(" -- ")
        end
        {
          title_intro: intro,
          title_main: main,
          title_part: part,
          language: lang,
          script: script(lang),
        }
      end

      # Return ISO script code.
      # @param lang [String]
      # @return [String]
      def script(lang)
        case lang
        when "en", "fr" then "Latn"
        end
      end

      # Fetch dates
      # @param doc [Nokogiri::HTML::Document]
      # @return [Array<Hash>]
      def fetch_dates(doc)
        dates = []
        publish_date = doc.xpath("//span[@itemprop='releaseDate']").text
        unless publish_date.empty?
          dates << { type: "published", on: publish_date }
        end
        dates
      end

      # rubocop:disable Metrics/MethodLength
      def fetch_contributors(title)
        title.sub(/\s.*/, "").split("/").map do |abbrev|
          case abbrev
          when "IEC"
            name = "International Electrotechnical Commission"
            url  = "www.iec.ch"
          else
            name = "International Organization for Standardization"
            url = "www.iso.org"
          end
          { entity: { name: name, url: url, abbreviation: abbrev },
            roles: ["publisher"] }
        end
      end
      # rubocop:enable Metrics/MethodLength

      # Fetch ICS.
      # @param doc [Nokogiri::HTML::Document]
      # @return [Array<Hash>]
      def fetch_ics(doc)
        doc.xpath("//strong[contains(text(), "\
                  "'ICS')]/../following-sibling::dd/div/a").map do |i|
          code = i.text.match(/[\d\.]+/).to_s.split "."
          { field: code[0], group: code[1], subgroup: code[2] }
        end
      end

      # Fetch links.
      # @param doc [Nokogiri::HTML::Document]
      # @param url [String]
      # @return [Array<Hash>]
      def fetch_link(doc, url)
        obp_elms = doc.xpath("//a[contains(@href, '/obp/ui/')]")
        obp = obp_elms.attr("href").value if obp_elms.any?
        rss = DOMAIN + doc.xpath("//a[contains(@href, 'rss')]").attr("href").value
        [
          { type: "src", content: url },
          { type: "obp", content: obp },
          { type: "rss", content: rss },
        ]
      end

      # Fetch copyright.
      # @param title [String]
      # @return [Hash]
      def fetch_copyright(title, doc)
        owner_name = title.match(/.*?(?=\s)/).to_s
        from = title.match(/(?<=:)\d{4}/).to_s
        if from.empty?
          from = doc.xpath("//span[@itemprop='releaseDate']").text.match(/\d{4}/).to_s
        end
        { owner: { name: owner_name }, from: from }
      end
    end

    # private
    #
    # def next_hits_page(next_page)
    #   page = @index.search @text, facetFilters: ['category:standard'],
    #                               page:         next_page
    #   page.each do |key, value|
    #     if key == 'hits'
    #       @docs[key] += value
    #     else
    #       @docs[key] = value
    #     end
    #   end
    # end
  end
  # rubocop:enable Metrics/ModuleLength
end
