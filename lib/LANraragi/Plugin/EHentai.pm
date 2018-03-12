package LANraragi::Plugin::EHentai;

use strict;
use warnings;
no warnings 'uninitialized';

#Plugins can freely use all Perl packages already installed on the system
#Try however to restrain yourself to the ones already installed for LRR (see tools/cpanfile) to avoid extra installations by the end-user.
use URI::Escape;
use Mojo::JSON qw(decode_json encode_json);
use Mojo::UserAgent;

#You can also use the LRR Internal API when fitting.
use LANraragi::Model::Plugins;

#Meta-information about your plugin.
sub plugin_info {

    return (
        #Standard metadata
        name        => "E-Hentai",
        namespace   => "ehplugin",
        author      => "Difegue",
        version     => "1.0",
        description => "Searches g.e-hentai for tags matching your archive.",

        #If your plugin uses/needs custom arguments, input their name here.
        #This name will be displayed in plugin configuration next to an input box for global arguments, and in archive edition for one-shot arguments.
        global_arg  => "Enable reverse image search? This might bring more false positives. (Type 'yes' to enable)",
        oneshot_arg => "E-H Gallery URL (Will attach tags matching this exact gallery to your archive)"
    );

}

#Mandatory function to be implemented by your plugin
sub get_tags {

    #LRR gives your plugin the recorded title/tags/thumbnail hash for the file, the filesystem path, and the custom arguments if available.
    shift;
    my ( $title, $tags, $thumbhash, $file, $globalarg, $oneshotarg ) = @_;

    #Use the logger to output status - they'll be passed to a specialized logfile and written to STDOUT.
    my $logger = LANraragi::Model::Utils::get_logger( "E-Hentai", "plugins" );

    #Work your magic here - You can create subroutines below to organize the code better
    my $gID    = "";
    my $gToken = "";

    #Quick regex to get the E-H archive ids from the provided url.
    if ( $oneshotarg =~ /.*\/g\/([0-9]*)\/([0-z]*)\/*.*/ ) {
        $gID    = $1;
        $gToken = $2;
    }
    else {
        #Craft URL for Text Search on EH if there's no user argument
        ( $gID, $gToken ) =
          &lookup_by_title( $title, $thumbhash, $globalarg, $tags );
    }

    #If no tokens were found, return a hash containing an error message. LRR will display that error to the client.
    if ( $gID eq "" || $gToken eq "" ) {
        $logger->info("No matching EH Gallery Found!");
        return ( error => "No matching EH Gallery Found!" );
    }
    else { $logger->debug("EH API Tokens are $gID / $gToken"); }

    my $newtags = &get_tags_from_EH( $gID, $gToken );

    #Return a hash containing the new metadata - it will be integrated in LRR.
    return ( tags => $newtags );
}

######
## EH Specific Methods
######

sub lookup_by_title {

    my $title              = $_[0];
    my $thumbhash          = $_[1];
    my $enable_imagesearch = $_[2] eq "yes";
    my $tags               = $_[3];

    my $logger = LANraragi::Model::Utils::get_logger( "E-Hentai", "plugins" );

    my $domain = "http://e-hentai.org/";

    my $URL =
        $domain
      . "?f_doujinshi=1&f_manga=1&f_artistcg=1&f_gamecg=1&f_western=1&f_non-h=1&f_imageset=1&f_cosplay=1&f_asianporn=1&f_misc=1"
      . "&f_search="
      . uri_escape_utf8($title);

    #Get the language tag, if it exists.
    if ( $tags =~ /.*language:\s?([^,]*),*.*/gi ) {
        $URL = $URL . "+language:$1";
    }

    $logger->debug("Using URL $URL (first pass, archive title)");

    my ( $gId, $gToken ) = &ehentai_parse($URL);

    if (   ( $gId eq "" || $gToken eq "" )
        && $thumbhash ne ""
        && $enable_imagesearch )
    {

        $logger->info("Reverse Image Search Enabled, trying...");

        #search with image SHA hash
        $URL =
            $domain
          . "?f_doujinshi=1&f_manga=1&f_artistcg=1&f_gamecg=1&f_western=1&f_non-h=1&f_imageset=1&f_cosplay=1&f_asianporn=1&f_misc=1"
          . "&f_shash="
          . $thumbhash
          . "&fs_similar=1";

        $logger->debug("Using URL $URL (second pass, archive thumbnail hash)");

        ( $gId, $gToken ) = &ehentai_parse($URL);
    }

    return ( $gId, $gToken );
}

#eHentaiLookup(URL)
#Performs a remote search on g.e-hentai, and builds the matching JSON to send to the API for data.
sub ehentai_parse() {

    my $URL = $_[0];
    my $ua  = Mojo::UserAgent->new;

    my $content = $ua->get($URL)->result->body;

    if (index($content, "Your IP address has been") != -1) {
        my $logger = LANraragi::Model::Utils::get_logger( "E-Hentai", "plugins" );
        $logger->error("Banned from EH for excessive pageloads.");
    }

    my $gID     = "";
    my $gToken  = "";

    #now for the parsing of the HTML we obtained.
    #the first occurence of <tr class="gtr0"> matches the first row of the results.
    #If it doesn't exist, what we searched isn't on E-hentai.
    my @benis = split( '<tr class="gtr0">', $content );

    #Inside that <tr>, we look for <div class="it5"> . the <a> tag inside has an href to the URL we want.
    my @final = split( '<div class="it5">', $benis[1] );

    my $url = ( split( 'e-hentai.org/g/', $final[1] ) )[1];

    my @values = ( split( '/', $url ) );

    $gID    = $values[0];
    $gToken = $values[1];

    #Returning shit yo
    return ( $gID, $gToken );
}

#getTagsFromEHAPI(gID, gToken)
#Executes an e-hentai API request with the given JSON and returns
sub get_tags_from_EH {

    my $uri    = 'http://e-hentai.org/api.php';
    my $gID    = $_[0];
    my $gToken = $_[1];

    my $ua = Mojo::UserAgent->new;

    my $logger = LANraragi::Model::Utils::get_logger( "E-Hentai", "plugins" );

    #Execute the request
    my $rep = $ua->post(
        $uri => json => {
            method    => "gdata",
            gidlist   => [ [ $gID, $gToken ] ],
            namespace => 1
        }
    )->result;

    my $jsonresponse = $rep->json;
    my $textrep      = $rep->body;
    $logger->debug("E-H API returned this JSON: $textrep");

    unless ( exists $jsonresponse->{"error"} ) {

        my $data = $jsonresponse->{"gmetadata"};
        my $tags = @$data[0]->{"tags"};

        my $return = join( ", ", @$tags );
        $logger->info("Sending the following tags to LRR: $return");
        return $return;
    } else {
    	#if an error occurs(no tags available) return an empty string.
        return "";
    }
}

1;