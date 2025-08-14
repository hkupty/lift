package stuff;

import org.slf4j.LoggerFactory;
import org.slf4j.Logger;

public class Stuff {
  static Logger logger = LoggerFactory.getLogger(Stuff.class);
  public static void main(String[] args) {
    logger.info("Hello lift from Penna");
    System.out.println("Hello Lift!");
  }
}
