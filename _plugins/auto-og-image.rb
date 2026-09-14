#!/usr/bin/env ruby
# frozen_string_literal: true

# Social preview fallback: when a post has no `image:` in its front matter,
# use the first image in its body for og:image / twitter:image.
#
# We deliberately do NOT set `page.image`, because Chirpy's post layout would
# then render that image again as a hero above the content. Instead we grab
# the first image from the markdown before rendering and swap the meta tags in
# the finished HTML head. Posts with an explicit `image:` are untouched, and
# posts with no image at all keep the site-wide `social_preview_image`.

module AutoOgImage
  MARKDOWN_IMG = /!\[[^\]]*\]\(\s*<?([^\s)>]+)>?(?:\s+"[^"]*")?\s*\)/.freeze
  HTML_IMG     = /<img\b[^>]*\bsrc=["']([^"']+)["']/i.freeze

  def self.first_image(markdown)
    candidates = []
    if (m = MARKDOWN_IMG.match(markdown))
      candidates << [m.begin(0), m[1]]
    end
    if (m = HTML_IMG.match(markdown))
      candidates << [m.begin(0), m[1]]
    end
    candidates.min_by(&:first)&.last
  end

  def self.absolute(src, site, post)
    return src if src =~ %r{\A[a-z]+://}i

    subpath = post.data['media_subpath'] || post.data['img_path']
    src = File.join(subpath, src) if subpath && !src.start_with?('/')

    base = site.config['url'].to_s + site.config['baseurl'].to_s
    File.join(base, src)
  end
end

Jekyll::Hooks.register :posts, :pre_render do |post|
  next if post.data['image']

  src = AutoOgImage.first_image(post.content)
  next unless src

  post.data['auto_og_image'] = AutoOgImage.absolute(src, post.site, post)
end

Jekyll::Hooks.register :posts, :post_render do |post|
  url = post.data['auto_og_image']
  next unless url && post.output

  escaped = url.gsub('&', '&amp;').gsub('"', '&quot;')
  post.output = post.output
    .gsub(/(<meta\s+property="og:image"\s+content=")[^"]*(")/) { "#{$1}#{escaped}#{$2}" }
    .gsub(/(<meta\s+property="twitter:image"\s+content=")[^"]*(")/) { "#{$1}#{escaped}#{$2}" }
end
